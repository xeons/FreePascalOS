{
  SysUtils for FreePascalOS: the generic Free Pascal SysUtils
  (rtl/objpas/sysutils) with the operating system parts on the kernel's
  system calls.

  Text is UTF-8. The Unicode string manager of fpwidestring (case
  mapping from the Unicode tables, comparison by the Unicode collation
  algorithm with the root collation) is installed whenever SysUtils is
  used, so AnsiUpperCase, AnsiCompareText and friends handle every
  character.

  File handles are kernel handles. File dates (FileAge, FileGetDate,
  TSearchRec.Time) use the packed DOS format of the generic code, in UTC
  like all times here: the kernel keeps no time zone. Attributes are
  derived from the node: faDirectory, faSymLink, faReadOnly when nobody
  may write, faHidden for names starting with a dot, faArchive for the
  rest.
}
{$mode objfpc}
{$modeswitch out}
{$H+}
unit SysUtils;

interface

{$define HAS_SLEEP}
{$define HAS_OSERROR}
{$define HAS_GETTICKCOUNT64}
{ FileSetDate by name sets the times by path (so a file's owner can set
  them without write access, as with touch). }
{$define OS_FILESETDATEBYNAME}
{$modeswitch typehelpers}
{$modeswitch advancedrecords}

{ The search state does not fit in a handle. }
{$define FINDHANDLE_IS_POINTER}
{ The kernel's file system calls take single byte (UTF-8) names. }
{$define SYSUTILS_HAS_ANSISTR_FILEUTIL_IMPL}
{$define SYSUTILS_HAS_ANSISTR_ENVVAR_IMPL}

{$i sysutilh.inc}

implementation

uses
  SysConst,
  { The root Unicode collation (DUCET), registered first so that the
    string manager compares by it; then the manager, installed before
    SysUtils initializes. }
  UnicodeDucet,
  fpwidestring;

{$i Abi.SystemCalls.inc}
{$i Abi.ErrorMessages.inc}

{$i sysutils.inc}

const
  SecondsPerDay = 86400;
  OwnerWrite = $80;
  GroupWrite = $10;
  OthersWrite = $02;

{ --- Helpers ---------------------------------------------------------------- }

{ Keeps a failed call's error for GetLastOSError; True if it failed. }
function CallFailed(CallResult: Int64): Boolean;
begin
  Result := CallResult < 0;
  if Result then
    SetLastSystemError(LongInt(-CallResult));
end;

function UnixTimeToFileDate(Seconds: Int64): LongInt;
begin
  Result := DateTimeToFileDate(UnixDateDelta + Seconds / SecondsPerDay);
end;

function PathInformation(const Path: RawByteString; FollowLinks: Boolean;
  out Information: TAbiFileInformation): Boolean;
begin
  Result := not CallFailed(SystemCall(CallGetPathInformation, QWord(PChar(Path)), QWord(@Information),
    Ord(FollowLinks), 0, 0, 0));
end;

function AttributesOf(const Name: RawByteString; const Information: TAbiFileInformation): LongInt;
begin
  case Information.Kind of
    KindDirectory: Result := faDirectory;
    KindSymbolicLink: Result := faSymLink;
  else
    Result := faArchive;
  end;
  if (Information.Mode and (OwnerWrite or GroupWrite or OthersWrite)) = 0 then
    Result := Result or faReadOnly;
  if (Name <> '') and (Name[1] = '.') and (Name <> '.') and (Name <> '..') then
    Result := Result or faHidden;
end;

{ The name after the last '/'. }
function BaseName(const Path: RawByteString): RawByteString;
var
  Index: Integer;
begin
  Index := Length(Path);
  while (Index > 0) and (Path[Index] <> '/') do
    Dec(Index);
  Result := Copy(Path, Index + 1, Length(Path));
end;

{ --- Files ------------------------------------------------------------------- }

function OpenWithFlags(const FileName: RawByteString; Flags: LongWord): THandle;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallOpen, QWord(PChar(FileName)), Flags, 0, 0, 0, 0);
  if CallFailed(CallResult) then
    Result := feInvalidHandle
  else
    Result := THandle(CallResult);
end;

function FileOpen(const FileName: RawByteString; Mode: Integer): THandle;
var
  Flags: LongWord;
begin
  case Mode and 3 of
    fmOpenWrite: Flags := OpenWrite;
    fmOpenReadWrite: Flags := OpenRead or OpenWrite;
  else
    Flags := OpenRead;
  end;
  Result := OpenWithFlags(FileName, Flags);
end;

function FileCreate(const FileName: RawByteString): THandle;
begin
  Result := OpenWithFlags(FileName, OpenRead or OpenWrite or OpenCreate or OpenTruncate);
end;

function FileCreate(const FileName: RawByteString; Rights: Integer): THandle;
begin
  Result := FileCreate(FileName);
end;

function FileCreate(const FileName: RawByteString; ShareMode: Integer; Rights: Integer): THandle;
begin
  Result := FileCreate(FileName);
end;

function FileRead(Handle: THandle; out Buffer; Count: LongInt): LongInt;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallRead, QWord(Int64(Handle)), QWord(@Buffer), QWord(Int64(Count)), 0, 0, 0);
  if CallFailed(CallResult) then
    Result := -1
  else
    Result := LongInt(CallResult);
end;

function FileWrite(Handle: THandle; const Buffer; Count: LongInt): LongInt;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallWrite, QWord(Int64(Handle)), QWord(@Buffer), QWord(Int64(Count)), 0, 0, 0);
  if CallFailed(CallResult) then
    Result := -1
  else
    Result := LongInt(CallResult);
end;

function FileSeek(Handle: THandle; FOffset: Int64; Origin: LongInt): Int64;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallSeek, QWord(Int64(Handle)), QWord(FOffset), LongWord(Origin), 0, 0, 0);
  if CallFailed(CallResult) then
    Result := -1
  else
    Result := CallResult;
end;

function FileSeek(Handle: THandle; FOffset, Origin: LongInt): LongInt;
begin
  Result := LongInt(FileSeek(Handle, Int64(FOffset), Origin));
end;

procedure FileClose(Handle: THandle);
begin
  SystemCall(CallClose, QWord(Int64(Handle)), 0, 0, 0, 0, 0);
end;

function FileTruncate(Handle: THandle; Size: Int64): Boolean;
begin
  Result := not CallFailed(SystemCall(CallSetFileSize, QWord(Int64(Handle)), QWord(Size), 0, 0, 0, 0));
end;

function FileAge(const FileName: RawByteString): LongInt;
var
  Information: TAbiFileInformation;
begin
  if PathInformation(FileName, True, Information) then
    Result := UnixTimeToFileDate(Information.ModificationTime)
  else
    Result := -1;
end;

function FileGetSymLinkTarget(const FileName: RawByteString; out SymLinkRec: TRawbyteSymLinkRec): Boolean;
var
  Buffer: array[0..MaxPathLen] of Char;
  CallResult: Int64;
  Information: TAbiFileInformation;
begin
  Result := False;
  SymLinkRec := Default(TRawbyteSymLinkRec);
  CallResult := SystemCall(CallReadSymbolicLink, QWord(PChar(FileName)), QWord(@Buffer[0]),
    SizeOf(Buffer) - 1, 0, 0, 0);
  if CallFailed(CallResult) then
    Exit;
  Buffer[CallResult] := #0;
  SymLinkRec.TargetName := Buffer;
  if PathInformation(FileName, True, Information) then
  begin
    SymLinkRec.Size := Information.SizeInBytes;
    SymLinkRec.Attr := AttributesOf(BaseName(FileName), Information);
  end;
  Result := True;
end;

function FileExists(const FileName: RawByteString; FollowLink: Boolean): Boolean;
var
  Information: TAbiFileInformation;
begin
  Result := PathInformation(FileName, FollowLink, Information) and (Information.Kind <> KindDirectory);
end;

function DirectoryExists(const Directory: RawByteString; FollowLink: Boolean): Boolean;
var
  Information: TAbiFileInformation;
begin
  Result := PathInformation(Directory, FollowLink, Information) and (Information.Kind = KindDirectory);
end;

function FileGetDate(Handle: THandle): LongInt;
var
  Information: TAbiFileInformation;
begin
  if CallFailed(SystemCall(CallGetHandleInformation, QWord(Int64(Handle)), QWord(@Information), 0, 0, 0, 0)) then
    Result := -1
  else
    Result := UnixTimeToFileDate(Information.ModificationTime);
end;

{ Changes setting both times to the file date Age. }
procedure TimeChanges(Age: LongInt; out Changes: TAbiAttributeChanges);
var
  Seconds: Int64;
begin
  Seconds := Round((FileDateToDateTime(Age) - UnixDateDelta) * SecondsPerDay);
  FillChar(Changes, SizeOf(Changes), 0);
  Changes.Fields := ChangeFieldModificationTime or ChangeFieldAccessTime;
  Changes.ModificationTime := Seconds;
  Changes.AccessTime := Seconds;
end;

{ 0, or the error of a failed call. }
function ZeroOrError(CallResult: Int64): LongInt;
begin
  if CallFailed(CallResult) then
    Result := GetLastSystemError
  else
    Result := 0;
end;

function FileSetDate(Handle: THandle; Age: LongInt): LongInt;
var
  Changes: TAbiAttributeChanges;
begin
  TimeChanges(Age, Changes);
  Result := ZeroOrError(SystemCall(CallSetHandleAttributes, QWord(Int64(Handle)), QWord(@Changes), 0, 0, 0, 0));
end;

{ By path, so it also works without write access to the file (for its
  owner) and on directories. }
function FileSetDate(const FileName: RawByteString; Age: LongInt): LongInt;
var
  Changes: TAbiAttributeChanges;
begin
  TimeChanges(Age, Changes);
  Result := ZeroOrError(SystemCall(CallSetPathAttributes, QWord(PChar(FileName)), QWord(@Changes), 1, 0, 0, 0));
end;

function FileGetAttr(const FileName: RawByteString): LongInt;
var
  Information: TAbiFileInformation;
begin
  if PathInformation(FileName, False, Information) then
    Result := AttributesOf(BaseName(FileName), Information)
  else
    Result := -1;
end;

{ Only faReadOnly can be set: it takes away every write permission;
  clearing it gives the owner write permission back. }
function FileSetAttr(const FileName: RawByteString; Attr: LongInt): LongInt;
var
  Information: TAbiFileInformation;
  Changes: TAbiAttributeChanges;
begin
  if not PathInformation(FileName, True, Information) then
    Exit(GetLastSystemError);
  FillChar(Changes, SizeOf(Changes), 0);
  Changes.Fields := ChangeFieldMode;
  if (Attr and faReadOnly) <> 0 then
    Changes.Mode := Information.Mode and not (OwnerWrite or GroupWrite or OthersWrite)
  else
    Changes.Mode := Information.Mode or OwnerWrite;
  Result := ZeroOrError(SystemCall(CallSetPathAttributes, QWord(PChar(FileName)), QWord(@Changes), 1, 0, 0, 0));
end;

function DeleteFile(const FileName: RawByteString): Boolean;
var
  Information: TAbiFileInformation;
begin
  Result := PathInformation(FileName, False, Information) and (Information.Kind <> KindDirectory) and
    not CallFailed(SystemCall(CallRemove, QWord(PChar(FileName)), 0, 0, 0, 0, 0));
end;

function RenameFile(const OldName, NewName: RawByteString): Boolean;
begin
  Result := not CallFailed(SystemCall(CallRename, QWord(PChar(OldName)), QWord(PChar(NewName)), 0, 0, 0, 0));
end;

{ --- Searching ---------------------------------------------------------------- }

type
  PSearchState = ^TSearchState;
  TSearchState = record
    { Ends with '/' (or is empty for the current directory). }
    Directory: RawByteString;
    Pattern: RawByteString;
    DirectoryHandle: Int64;
    SearchAttr: LongInt;
    { No wildcards: the one name has been reported. }
    SingleName: Boolean;
  end;

{ Shell style matching of '*' and '?'. }
function NameMatches(const Pattern, Name: RawByteString): Boolean;

  function MatchFrom(PatternIndex, NameIndex: Integer): Boolean;
  begin
    while PatternIndex <= Length(Pattern) do
    begin
      case Pattern[PatternIndex] of
        '*':
          begin
            while (PatternIndex <= Length(Pattern)) and (Pattern[PatternIndex] = '*') do
              Inc(PatternIndex);
            if PatternIndex > Length(Pattern) then
              Exit(True);
            while NameIndex <= Length(Name) do
            begin
              if MatchFrom(PatternIndex, NameIndex) then
                Exit(True);
              Inc(NameIndex);
            end;
            Exit(False);
          end;
        '?':
          if NameIndex > Length(Name) then
            Exit(False);
      else
        if (NameIndex > Length(Name)) or (Pattern[PatternIndex] <> Name[NameIndex]) then
          Exit(False);
      end;
      Inc(PatternIndex);
      Inc(NameIndex);
    end;
    Result := NameIndex > Length(Name);
  end;

begin
  Result := MatchFrom(1, 1);
end;

{ Fills Rslt for Path if its attributes pass the search. }
function ReportEntry(State: PSearchState; const Path, Name: RawByteString; var Rslt: TAbstractSearchRec;
  var FoundName: RawByteString): Boolean;
var
  Information: TAbiFileInformation;
  Attributes: LongInt;
begin
  Result := False;
  if not PathInformation(Path, False, Information) then
    Exit;
  Attributes := AttributesOf(Name, Information);
  { Directories, hidden and system entries only when asked for. }
  if (Attributes and (faDirectory or faHidden or faSysFile) and not State^.SearchAttr) <> 0 then
    Exit;
  Rslt.Attr := Attributes;
  Rslt.Size := Information.SizeInBytes;
  Rslt.Time := UnixTimeToFileDate(Information.ModificationTime);
  FoundName := Name;
  Result := True;
end;

function InternalFindNext(var Rslt: TAbstractSearchRec; var Name: RawByteString): LongInt;
var
  State: PSearchState;
  Entry: TAbiDirectoryEntry;
  EntryName: RawByteString;
begin
  Result := -1;
  State := PSearchState(Rslt.FindHandle);
  if (State = nil) or State^.SingleName then
    Exit;
  while SystemCall(CallReadDirectory, QWord(State^.DirectoryHandle), QWord(@Entry), 0, 0, 0, 0) > 0 do
  begin
    EntryName := Entry.Name;
    if NameMatches(State^.Pattern, EntryName) and
       ReportEntry(State, State^.Directory + EntryName, EntryName, Rslt, Name) then
      Exit(0);
  end;
end;

function InternalFindFirst(const Path: RawByteString; Attr: LongInt; out Rslt: TAbstractSearchRec;
  var Name: RawByteString): LongInt;
var
  State: PSearchState;
  DirectoryPath: RawByteString;
begin
  Result := -1;
  FillChar(Rslt, SizeOf(Rslt), 0);
  if Path = '' then
    Exit;
  New(State);
  State^.DirectoryHandle := -1;
  State^.SearchAttr := Attr or faArchive or faReadOnly;
  State^.Directory := Copy(Path, 1, Length(Path) - Length(BaseName(Path)));
  State^.Pattern := BaseName(Path);
  State^.SingleName := (Pos('*', State^.Pattern) = 0) and (Pos('?', State^.Pattern) = 0);
  Rslt.FindHandle := State;
  if State^.SingleName then
  begin
    if ReportEntry(State, Path, State^.Pattern, Rslt, Name) then
      Result := 0;
  end
  else
  begin
    DirectoryPath := State^.Directory;
    if DirectoryPath = '' then
      DirectoryPath := '.';
    State^.DirectoryHandle := SystemCall(CallOpen, QWord(PChar(DirectoryPath)), OpenRead, 0, 0, 0, 0);
    if State^.DirectoryHandle >= 0 then
      Result := InternalFindNext(Rslt, Name);
  end;
  if Result <> 0 then
    InternalFindClose(Rslt.FindHandle);
end;

procedure InternalFindClose(var Handle: Pointer);
var
  State: PSearchState;
begin
  State := PSearchState(Handle);
  if State = nil then
    Exit;
  if State^.DirectoryHandle >= 0 then
    SystemCall(CallClose, QWord(State^.DirectoryHandle), 0, 0, 0, 0, 0);
  Dispose(State);
  Handle := nil;
end;

{ --- Disks -------------------------------------------------------------------- }

{ There are no drive letters: drive 0 means the volume of the current
  directory, every other number the system volume. }
function VolumeBytes(Drive: Byte; Free: Boolean): Int64;
var
  Information: TAbiVolumeInformation;
  Path: RawByteString;
begin
  if Drive = 0 then
    Path := '.'
  else
    Path := '/';
  if CallFailed(SystemCall(CallGetVolumeInformation, QWord(PChar(Path)), QWord(@Information), 0, 0, 0, 0)) then
    Exit(-1);
  if not Free then
    Result := Information.TotalBytes
  else if Information.HasFreeSpace <> 0 then
    Result := Information.FreeBytes
  else
    Result := -1;
end;

function DiskFree(Drive: Byte): Int64;
begin
  Result := VolumeBytes(Drive, True);
end;

function DiskSize(Drive: Byte): Int64;
begin
  Result := VolumeBytes(Drive, False);
end;

{ --- Miscellaneous ------------------------------------------------------------ }

procedure SysBeep;
const
  Bell: Char = #7;
begin
  { The bell character, on the console. }
  FileWrite(StdOutputHandle, Bell, 1);
end;

procedure Sleep(Milliseconds: Cardinal);
begin
  SystemCall(CallSleep, Milliseconds, 0, 0, 0, 0, 0);
end;

function GetTickCount64: QWord;
begin
  Result := QWord(SystemCall(CallGetTime, 1, 0, 0, 0, 0, 0));
end;

function GetLastOSError: Integer;
begin
  Result := GetLastSystemError;
end;

procedure GetLocalTime(var SystemTime: TSystemTime);
var
  Seconds: Int64;
begin
  Seconds := SystemCall(CallGetTime, 0, 0, 0, 0, 0, 0);
  DateTimeToSystemTime(UnixDateDelta + Seconds / SecondsPerDay, SystemTime);
end;

function SysErrorMessage(ErrorCode: Integer): String;
begin
  Result := AbiErrorMessage(ErrorCode);
end;

{ --- Environment and processes ---------------------------------------------- }

function GetEnvironmentVariable(const EnvVar: String): String;
var
  Entry: PPChar;
  NameLength: Integer;
begin
  Result := '';
  NameLength := Length(EnvVar);
  Entry := envp;
  while (Entry <> nil) and (Entry^ <> nil) do
  begin
    if (StrLComp(Entry^, PChar(EnvVar), NameLength) = 0) and (Entry^[NameLength] = '=') then
      Exit(StrPas(Entry^ + NameLength + 1));
    Inc(Entry);
  end;
end;

function GetEnvironmentVariableCount: Integer;
var
  Entry: PPChar;
begin
  Result := 0;
  Entry := envp;
  while (Entry <> nil) and (Entry^ <> nil) do
  begin
    Inc(Result);
    Inc(Entry);
  end;
end;

function GetEnvironmentString(Index: Integer): {$ifdef FPC_RTL_UNICODE}UnicodeString{$else}AnsiString{$endif};
begin
  if (Index >= 1) and (Index <= GetEnvironmentVariableCount) then
    Result := StrPas(envp[Index - 1])
  else
    Result := '';
end;

{ Runs Path with Arguments (nil terminated), inheriting the standard
  handles, and waits for it; returns its exit code. }
function RunAndWait(const Path: RawByteString; Arguments: PPChar): Integer;
var
  Creation: TAbiProcessCreation;
  Handle: Int64;
  Status: Int64;
  Error: EOSError;
begin
  FillChar(Creation, SizeOf(Creation), 0);
  Creation.Path := PChar(Path);
  Creation.Arguments := Arguments;
  Creation.Environment := envp;
  Creation.InputHandle := StdInputHandle;
  Creation.OutputHandle := StdOutputHandle;
  Creation.ErrorHandle := StdErrorHandle;
  Creation.GroupId := GroupInherit;
  Handle := SystemCall(CallCreateProcess, QWord(@Creation), 0, 0, 0, 0, 0);
  if Handle < 0 then
  begin
    Error := EOSError.CreateFmt(SExecuteProcessFailed, [Path, Integer(-Handle)]);
    Error.ErrorCode := Integer(-Handle);
    raise Error;
  end;
  Status := SystemCall(CallWaitForProcess, QWord(Handle), QWord(Int64(InfiniteWait)), 0, 0, 0, 0);
  SystemCall(CallClose, QWord(Handle), 0, 0, 0, 0, 0);
  Result := Integer(Status);
end;

function ExecuteProcess(const Path: RawByteString; const ComLine: array of RawByteString;
  Flags: TExecuteFlags = []): Integer;
var
  Arguments: array of PChar;
  Index: Integer;
begin
  SetLength(Arguments, Length(ComLine) + 2);
  Arguments[0] := PChar(Path);
  for Index := 0 to High(ComLine) do
    Arguments[Index + 1] := PChar(ComLine[Index]);
  Arguments[Length(ComLine) + 1] := nil;
  Result := RunAndWait(Path, @Arguments[0]);
end;

{ Splits a command line at spaces; double quotes group words. }
function SplitCommandLine(const ComLine: RawByteString): TStringArray;
var
  Index: Integer;
  Word: RawByteString;
  InQuotes: Boolean;
  HaveWord: Boolean;
begin
  Result := nil;
  Word := '';
  InQuotes := False;
  HaveWord := False;
  for Index := 1 to Length(ComLine) do
  begin
    if ComLine[Index] = '"' then
    begin
      InQuotes := not InQuotes;
      HaveWord := True;
    end
    else if (ComLine[Index] = ' ') and not InQuotes then
    begin
      if HaveWord then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Word;
      end;
      Word := '';
      HaveWord := False;
    end
    else
    begin
      Word := Word + ComLine[Index];
      HaveWord := True;
    end;
  end;
  if HaveWord then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Word;
  end;
end;

function ExecuteProcess(const Path: RawByteString; const ComLine: RawByteString;
  Flags: TExecuteFlags = []): Integer;
var
  Words: TStringArray;
  Arguments: array of RawByteString;
  Index: Integer;
begin
  Words := SplitCommandLine(ComLine);
  SetLength(Arguments, Length(Words));
  for Index := 0 to High(Words) do
    Arguments[Index] := Words[Index];
  Result := ExecuteProcess(Path, Arguments, Flags);
end;

function ExecuteProcess(const Path: UnicodeString; const ComLine: UnicodeString;
  Flags: TExecuteFlags = []): Integer;
begin
  Result := ExecuteProcess(ToSingleByteFileSystemEncodedFileName(Path),
    ToSingleByteFileSystemEncodedFileName(ComLine), Flags);
end;

function ExecuteProcess(const Path: UnicodeString; const ComLine: array of UnicodeString;
  Flags: TExecuteFlags = []): Integer;
var
  Arguments: array of RawByteString;
  Index: Integer;
begin
  SetLength(Arguments, Length(ComLine));
  for Index := 0 to High(ComLine) do
    Arguments[Index] := ToSingleByteFileSystemEncodedFileName(ComLine[Index]);
  Result := ExecuteProcess(ToSingleByteFileSystemEncodedFileName(Path), Arguments, Flags);
end;

{ --- Initialization -------------------------------------------------------------- }

{ The single byte case tables: ASCII only, since bytes from 128 up are
  parts of UTF-8 characters, which the string manager handles. }
procedure InitAnsi;
var
  Index: Integer;
begin
  for Index := 0 to 255 do
  begin
    UpperCaseTable[Index] := Chr(Index);
    LowerCaseTable[Index] := Chr(Index);
  end;
  for Index := Ord('a') to Ord('z') do
    UpperCaseTable[Index] := Chr(Index - 32);
  for Index := Ord('A') to Ord('Z') do
    LowerCaseTable[Index] := Chr(Index + 32);
end;

procedure InitInternational;
begin
  InitInternationalGeneric;
  InitAnsi;
end;

initialization
  InitExceptions;
  InitInternational;
  SysConfigDir := '/etc';
  OnBeep := @SysBeep;
finalization
  FreeTerminateProcs;
  DoneExceptions;
end.
