{
  The contents of libcoreutils.so: helpers shared by the command line
  tools. Compiling this unit compiles all of them.
}
unit Util.Contents;

{$mode objfpc}

interface

uses
  Util.Messages,
  Util.Options,
  Util.Input,
  Util.Paths,
  Util.Sorting,
  Util.Sizes,
  Util.Directories,
  Util.FileTree,
  Util.DigestTool,
  Util.BaseEncoding,
  Util.Modes,
  Util.Dates,
  Util.Accounts,
  Util.Commands,
  Util.RegularExpressions,
  Util.LineEditor,
  Util.Globbing,
  Util.Passwords;

implementation

end.
