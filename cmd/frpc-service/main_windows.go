//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"golang.org/x/sys/windows/svc"
)

const serviceName = "frp-agent"

type frpcService struct{}

func (frpcService) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}

	executable, err := os.Executable()
	if err != nil {
		return true, 1
	}
	dir := filepath.Dir(executable)
	logFile, err := os.OpenFile(filepath.Join(dir, "frpc.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return true, 1
	}
	defer logFile.Close()

	cmd := exec.Command(filepath.Join(dir, "frpc.exe"), "-c", filepath.Join(dir, "frpc.toml"))
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		_, _ = fmt.Fprintf(logFile, "failed to start frpc: %v\n", err)
		return true, 1
	}

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

	for {
		select {
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				status <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				if cmd.Process != nil {
					_ = cmd.Process.Kill()
				}
				<-done
				return false, 0
			}
		case err := <-done:
			if err != nil && !errors.Is(err, os.ErrProcessDone) {
				_, _ = fmt.Fprintf(logFile, "frpc exited: %v\n", err)
				return true, 1
			}
			return false, 0
		}
	}
}

func main() {
	isService, err := svc.IsWindowsService()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if !isService {
		fmt.Fprintf(os.Stderr, "%s is a Windows service host; start it through the Service Control Manager\n", serviceName)
		os.Exit(2)
	}
	if err := svc.Run(serviceName, frpcService{}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
