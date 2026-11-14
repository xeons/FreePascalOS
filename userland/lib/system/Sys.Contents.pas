{
  The contents of libsystem.so.

  Compiling this unit compiles every unit of the library; the resulting
  object files are linked into the shared library. Programs use the
  individual units, never this one.
}
unit Sys.Contents;

{$mode objfpc}

interface

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Time,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Sys.Memory,
  Sys.Text,
  Sys.Streams,
  Sys.Format,
  Sys.Files,
  Sys.Environment,
  Sys.Processes,
  Sys.Time,
  Sys.Libraries,
  Sys.Information,
  Sys.Console;

implementation

end.
