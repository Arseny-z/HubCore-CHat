// Package hubcorebind is an umbrella module that re-exports both yggbind and
// rnsbind so they compile into a single .aar with one copy of the Go runtime.
//
// gomobile bind produces go.Seq / go.Universe classes in every .aar.
// Two separate .aar files cause "Duplicate class" errors at build time.
// This module solves that by binding both packages in one invocation.
package hubcorebind

// Force the Go compiler to include both packages.
import (
	_ "hubcore/rnsbind"
	_ "hubcore/yggbind"
)
