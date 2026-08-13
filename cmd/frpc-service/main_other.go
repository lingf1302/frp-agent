//go:build !windows

package main

import "fmt"

func main() {
	fmt.Println("frpc-service is only used as a Windows service host")
}
