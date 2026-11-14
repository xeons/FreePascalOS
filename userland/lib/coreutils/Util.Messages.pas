{
  Diagnostics in the usual command line form:

    ls: cannot access 'missing': No such file or directory

  Every message starts with the program name (taken from argument 0
  without its directory).
}
unit Util.Messages;

{$mode objfpc}

interface

uses
  Sys.Format;

function ProgramName: PChar;

{ "<program>: <message>" on standard error. }
procedure Report(Format: PChar; const Arguments: array of TFormatArgument);
{ "<program>: <message>: <error text>" on standard error. }
procedure ReportError(ErrorCode: LongInt; Format: PChar; const Arguments: array of TFormatArgument);
{ Report, then end the program with ExitStatus. }
procedure Fail(ExitStatus: LongInt; Format: PChar; const Arguments: array of TFormatArgument);
procedure FailWithError(ExitStatus: LongInt; ErrorCode: LongInt; Format: PChar;
  const Arguments: array of TFormatArgument);
{ "Try '<program> --help' for more information." and exit status 1. }
procedure FailWithUsageHint(Format: PChar; const Arguments: array of TFormatArgument);

implementation

uses
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Streams,
  Sys.Text;

function ProgramName: PChar;
var
  FullName: PChar;
  LastSlash: PtrInt;
begin
  FullName := Argument(0);
  LastSlash := FindLastCharacter(FullName, '/');
  if LastSlash >= 0 then
    Result := FullName + LastSlash + 1
  else
    Result := FullName;
  if Result^ = #0 then
    Result := 'program';
end;

procedure Report(Format: PChar; const Arguments: array of TFormatArgument);
begin
  FlushStream(StandardOutput);
  WriteText(StandardError, ProgramName);
  WriteText(StandardError, ': ');
  WriteFormatted(StandardError, Format, Arguments);
  WriteCharacter(StandardError, #10);
end;

procedure ReportError(ErrorCode: LongInt; Format: PChar; const Arguments: array of TFormatArgument);
begin
  FlushStream(StandardOutput);
  WriteText(StandardError, ProgramName);
  WriteText(StandardError, ': ');
  WriteFormatted(StandardError, Format, Arguments);
  WriteText(StandardError, ': ');
  WriteText(StandardError, ErrorMessage(ErrorCode));
  WriteCharacter(StandardError, #10);
end;

procedure Fail(ExitStatus: LongInt; Format: PChar; const Arguments: array of TFormatArgument);
begin
  Report(Format, Arguments);
  Halt(ExitStatus);
end;

procedure FailWithError(ExitStatus: LongInt; ErrorCode: LongInt; Format: PChar;
  const Arguments: array of TFormatArgument);
begin
  ReportError(ErrorCode, Format, Arguments);
  Halt(ExitStatus);
end;

procedure FailWithUsageHint(Format: PChar; const Arguments: array of TFormatArgument);
begin
  Report(Format, Arguments);
  WriteFormatted(StandardError, 'Try ''%s --help'' for more information.'#10, [ArgumentText(ProgramName)]);
  Halt(1);
end;

end.
