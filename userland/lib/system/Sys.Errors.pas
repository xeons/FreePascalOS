{
  Error codes and their messages.

  System calls report failure as a negative result; the error code is
  the negated value. These messages follow the wording Unix users know.
}
unit Sys.Errors;

{$mode objfpc}

interface

{ Turns a negative system call result into its error code (0 if the
  result is not an error). }
function ErrorCodeOf(CallResult: Int64): LongInt;

function ErrorMessage(Code: LongInt): PChar;

implementation

uses
  Abi.SystemCalls;

function ErrorCodeOf(CallResult: Int64): LongInt;
begin
  if CallResult < 0 then
    Result := LongInt(-CallResult)
  else
    Result := 0;
end;

function ErrorMessage(Code: LongInt): PChar;
begin
  case Code of
    ErrorNone: Result := 'Success';
    ErrorNotPermitted: Result := 'Operation not permitted';
    ErrorNotFound: Result := 'No such file or directory';
    ErrorIo: Result := 'Input/output error';
    ErrorBadExecutable: Result := 'Exec format error';
    ErrorBadHandle: Result := 'Bad file descriptor';
    ErrorNoChildProcess: Result := 'No child processes';
    ErrorOutOfMemory: Result := 'Cannot allocate memory';
    ErrorBadAddress: Result := 'Bad address';
    ErrorBusy: Result := 'Device or resource busy';
    ErrorExists: Result := 'File exists';
    ErrorCrossVolume: Result := 'Invalid cross-device link';
    ErrorNotDirectory: Result := 'Not a directory';
    ErrorIsDirectory: Result := 'Is a directory';
    ErrorInvalidArgument: Result := 'Invalid argument';
    ErrorTooManyHandles: Result := 'Too many open files';
    ErrorNoSpace: Result := 'No space left on device';
    ErrorIllegalSeek: Result := 'Illegal seek';
    ErrorReadOnly: Result := 'Read-only file system';
    ErrorBrokenPipe: Result := 'Broken pipe';
    ErrorNameTooLong: Result := 'File name too long';
    ErrorNotImplemented: Result := 'Function not implemented';
    ErrorDirectoryNotEmpty: Result := 'Directory not empty';
    ErrorTooManyLinks: Result := 'Too many levels of symbolic links';
    ErrorUnsupported: Result := 'Operation not supported';
    ErrorCorrupted: Result := 'Structure needs cleaning';
  else
    Result := 'Unknown error';
  end;
end;

end.
