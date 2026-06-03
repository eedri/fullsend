package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/fullsend-ai/fullsend/internal/cli"
)

// exitCoder allows commands to signal specific process exit codes.
// Errors implementing this interface cause the CLI to exit with the
// returned code instead of the default 1.
type exitCoder interface {
	ExitCode() int
}

func main() {
	if err := cli.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		var ec exitCoder
		if errors.As(err, &ec) {
			os.Exit(ec.ExitCode())
		}
		os.Exit(1)
	}
}
