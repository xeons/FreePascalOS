{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The archive test's reading checks: every line of make-fixtures.py's
  manifest (formats, counts, members and their data, encrypted and
  damaged members, unsafe names), then extraction into folders, random
  access in a .tar.gz, browsing folders and cancelling.
}
unit ArchiveTest.Reading;

{$mode objfpc}
{$H+}

interface

procedure TestFixtures(const FixtureDirectory, WorkDirectory: string);
procedure TestExtractAll(const FixtureDirectory, WorkDirectory: string);
procedure TestRandomAccess(const FixtureDirectory: string);
procedure TestFolders(const FixtureDirectory: string);
procedure TestCancelling(const FixtureDirectory: string);

implementation

uses
  Classes,
  SysUtils,
  StrUtils,
  BaseUnix,
  TestChecks,
  Archive.Entries,
  Archive.Readers,
  Archive.Extraction,
  Archive.Folders,
  ArchiveTest.Support;

var
  OpenReaders: TStringList;

function ReaderFor(const Directory, Archive: string): TArchiveReader;
var
  Found: Integer;
begin
  Found := OpenReaders.IndexOf(Archive);
  if Found >= 0 then
    Exit(TArchiveReader(OpenReaders.Objects[Found]));
  Result := OpenArchive(Directory + '/' + Archive);
  OpenReaders.AddObject(Archive, Result);
end;

procedure CloseReaders;
var
  Index: Integer;
begin
  for Index := 0 to OpenReaders.Count - 1 do
    OpenReaders.Objects[Index].Free;
  OpenReaders.Clear;
end;

function FormatName(Format: TArchiveFormat): string;
begin
  case Format of
    ArchiveZip: Result := 'zip';
    ArchiveTar: Result := 'tar';
    ArchiveTarGzip: Result := 'targz';
    ArchiveTarZstd: Result := 'tarzst';
    ArchiveTarXz: Result := 'tarxz';
  else
    Result := 'unknown';
  end;
end;

procedure CheckEntryLine(const Directory: string; const Fields: TStringArray);
var
  Reader: TArchiveReader;
  Index: Integer;
  Entry: TArchiveEntry;
  Prefix, Data: string;
begin
  Prefix := Fields[1] + ' ' + Fields[2] + ': ';
  Reader := ReaderFor(Directory, Fields[1]);
  Index := Reader.IndexOf(Fields[2]);
  Check(Index >= 0, Prefix + 'listed');
  if Index < 0 then
    Exit;
  Entry := Reader[Index];
  Check(Entry.Name = Fields[2], Prefix + 'name');
  Check(Entry.IsFolder = (Fields[3] = 'd'), Prefix + 'folder or not');
  Check(Entry.IsLink = (Fields[3] = 'l'), Prefix + 'link or not');
  Check(Entry.ModificationTime = StrToInt64(Fields[6]),
    Prefix + Format('time %s (got %d)', [Fields[6], Entry.ModificationTime]));
  Check(Entry.Mode = LongWord(StrToInt('&' + Fields[7])),
    Prefix + Format('mode %s (got %s)', [Fields[7], OctalText(Entry.Mode)]));
  Check(not Entry.Encrypted, Prefix + 'not encrypted');
  if Entry.IsFolder then
    Exit;
  Check(Entry.Size = StrToQWord(Fields[4]), Prefix + Format('size %s (got %d)', [Fields[4], Entry.Size]));
  if Entry.IsLink then
    Check(Entry.LinkTarget = Fields[8], Prefix + 'link target "' + Entry.LinkTarget + '"');
  try
    Data := ExtractedData(Reader, Index);
    Check(Length(Data) = StrToInt(Fields[4]), Prefix + 'extracted size');
    Check(CrcHex(Data) = Fields[5], Prefix + 'extracted CRC-32');
  except
    on Error: Exception do
      Check(False, Prefix + 'extraction failed: ' + Error.Message);
  end;
end;

procedure CheckRefusedExtraction(const Directory: string; const Fields: TStringArray; WantEncrypted: Boolean);
var
  Reader: TArchiveReader;
  Index: Integer;
  Refused: Boolean;
  Message: string;
begin
  Reader := ReaderFor(Directory, Fields[1]);
  Index := Reader.IndexOf(Fields[2]);
  Check(Index >= 0, Fields[1] + ' ' + Fields[2] + ': listed');
  if Index < 0 then
    Exit;
  if WantEncrypted then
    Check(Reader[Index].Encrypted, Fields[1] + ' ' + Fields[2] + ': reported encrypted');
  Refused := False;
  Message := '';
  try
    ExtractedData(Reader, Index);
  except
    on Error: EArchiveError do
    begin
      Refused := True;
      Message := Error.Message;
    end;
  end;
  Check(Refused, Fields[1] + ' ' + Fields[2] + ': extraction refused (' + Message + ')');
  if WantEncrypted then
    Check(Pos('encrypted', Message) > 0, Fields[1] + ': the error says it is encrypted')
  else
    Check(Pos('CRC', Message) > 0, Fields[1] + ': the error names the CRC');
end;

procedure CheckUnsafeLine(const Directory, WorkDirectory: string; const Fields: TStringArray);
var
  Reader: TArchiveReader;
  Target: string;
  Skipped: Integer;
begin
  Reader := ReaderFor(Directory, Fields[1]);
  Target := WorkDirectory + '/unsafe/inner';
  RemoveTree(WorkDirectory + '/unsafe');
  Skipped := ExtractAll(Reader, Target);
  Check(Skipped = StrToInt(Fields[2]), Format('%s: %s unsafe names left out (got %d)', [Fields[1], Fields[2], Skipped]));
  Check(FileExists(Target + '/ok.txt'), Fields[1] + ': the safe name extracted');
  Check(not FileExists(WorkDirectory + '/unsafe/evil.txt') and not FileExists(WorkDirectory + '/unsafe/up.txt'),
    Fields[1] + ': nothing written outside the folder');
  Check(not FileExists('/absolute.txt'), Fields[1] + ': nothing written at the root');
end;

procedure TestFixtures(const FixtureDirectory, WorkDirectory: string);
var
  Manifest: TStringList;
  Index: Integer;
  Fields: TStringArray;
  Path: string;
begin
  Manifest := TStringList.Create;
  try
    Manifest.LoadFromFile(FixtureDirectory + '/manifest.txt');
    for Index := 0 to Manifest.Count - 1 do
    begin
      if Manifest[Index] = '' then
        Continue;
      Fields := SplitTabs(Manifest[Index]);
      Path := FixtureDirectory + '/' + Fields[1];
      try
        if Fields[0] = 'format' then
        begin
          Check(FormatName(DetectArchiveFormat(Path)) = Fields[2], Fields[1] + ': format ' + Fields[2] +
            ' (got ' + FormatName(DetectArchiveFormat(Path)) + ')');
          Check(IsArchiveFile(Path) = (Fields[2] <> 'unknown'), Fields[1] + ': IsArchiveFile');
          if Fields[2] = 'unknown' then
          begin
            try
              OpenArchive(Path).Free;
              Check(False, Fields[1] + ': OpenArchive refuses it');
            except
              on EArchiveError do
                Check(True, Fields[1] + ': OpenArchive refuses it');
            end;
          end
          else
            Check(ReaderFor(FixtureDirectory, Fields[1]).Format = DetectArchiveFormat(Path),
              Fields[1] + ': the reader says its format');
        end
        else if Fields[0] = 'count' then
          Check(ReaderFor(FixtureDirectory, Fields[1]).Count = StrToInt(Fields[2]),
            Format('%s: %s members (got %d)', [Fields[1], Fields[2], ReaderFor(FixtureDirectory, Fields[1]).Count]))
        else if Fields[0] = 'entry' then
          CheckEntryLine(FixtureDirectory, Fields)
        else if Fields[0] = 'encrypted' then
          CheckRefusedExtraction(FixtureDirectory, Fields, True)
        else if Fields[0] = 'badcrc' then
          CheckRefusedExtraction(FixtureDirectory, Fields, False)
        else if Fields[0] = 'unsafe' then
          CheckUnsafeLine(FixtureDirectory, WorkDirectory, Fields);
      except
        on Error: Exception do
          Check(False, Manifest[Index] + ': ' + Error.ClassName + ': ' + Error.Message);
      end;
    end;
  finally
    Manifest.Free;
    CloseReaders;
  end;
end;

procedure TestExtractAll(const FixtureDirectory, WorkDirectory: string);
var
  Reader: TArchiveReader;
  Target, LinkTarget: string;
  Status: Stat;
  Skipped: Integer;
begin
  Target := WorkDirectory + '/extracted';
  RemoveTree(Target);
  Reader := OpenArchive(FixtureDirectory + '/zip-deflated.zip');
  try
    Skipped := ExtractAll(Reader, Target);
    Check(Skipped = 0, 'zip ExtractAll: nothing unsafe');
  finally
    Reader.Free;
  end;
  Check(DirectoryExists(Target + '/docs'), 'zip ExtractAll: folder made');
  Check(DirectoryExists(Target + '/bin'), 'zip ExtractAll: folder of a file made');
  Check(ReadWholeFile(Target + '/docs/readme.txt') = DupeString('Hello from the archive test.'#10, 20),
    'zip ExtractAll: file content');
  Check(FileExists(Target + '/docs/empty.txt') and (Length(ReadWholeFile(Target + '/docs/empty.txt')) = 0),
    'zip ExtractAll: empty file');
  Check(FileExists(Target + '/docs/caf'#$C3#$A9' '#$E6#$97#$A5#$E6#$9C#$AC'.txt'), 'zip ExtractAll: Unicode name');
  Check((FpStat(Target + '/bin/run.sh', Status) = 0) and ((Status.st_mode and &777) = &755),
    'zip ExtractAll: executable mode');
  Check((FpStat(Target + '/data/big.bin', Status) = 0) and ((Status.st_mode and &777) = &600),
    'zip ExtractAll: private mode');
  Check((FpStat(Target + '/docs/readme.txt', Status) = 0) and (Status.st_mtime = 1715953530),
    'zip ExtractAll: file time');
  Check((FpStat(Target + '/stamped.txt', Status) = 0) and (Status.st_mtime = 1700000001),
    'zip ExtractAll: extended timestamp time');
  Check((FpStat(Target + '/docs', Status) = 0) and (Status.st_mtime = 1715953530),
    'zip ExtractAll: folder time set after its contents');
  LinkTarget := fpReadLink(Target + '/links/readme');
  Check(LinkTarget = '../docs/readme.txt', 'zip ExtractAll: symbolic link made (' + LinkTarget + ')');

  Target := WorkDirectory + '/extracted-tgz';
  RemoveTree(Target);
  Reader := OpenArchive(FixtureDirectory + '/tar-pax.tar.gz');
  try
    ExtractAll(Reader, Target);
  finally
    Reader.Free;
  end;
  Check(ReadWholeFile(Target + '/top/hello.txt') = 'hello tar'#10, 'tar.gz ExtractAll: file content');
  Check(ReadWholeFile(Target + '/top/hard') = 'hello tar'#10, 'tar.gz ExtractAll: hard link as a copy');
  Check(Length(ReadWholeFile(Target + '/top/big.bin')) = 150000, 'tar.gz ExtractAll: big file');
  Check(fpReadLink(Target + '/top/link') = 'hello.txt', 'tar.gz ExtractAll: symbolic link');
  Check(FileExists(Target + '/top/' + #$C3#$BC'ber '#$E6#$97#$A5#$E6#$9C#$AC'.txt'), 'tar.gz ExtractAll: pax Unicode name');
  Check((FpStat(Target + '/top/fraction.txt', Status) = 0) and (Status.st_mtime = 1700000000),
    'tar.gz ExtractAll: pax time');
end;

procedure TestRandomAccess(const FixtureDirectory: string);
var
  Reader: TArchiveReader;
  Index: Integer;
  Hello, Big: string;
begin
  Reader := OpenArchive(FixtureDirectory + '/tar-pax.tar.gz');
  try
    Big := ExtractedData(Reader, Reader.IndexOf('top/big.bin'));
    Hello := ExtractedData(Reader, Reader.IndexOf('top/hello.txt'));
    Check(Hello = 'hello tar'#10, 'tar.gz: going back to an earlier member');
    Check(ExtractedData(Reader, Reader.IndexOf('top/big.bin')) = Big, 'tar.gz: forward again');
    for Index := Reader.Count - 1 downto 0 do
      ExtractedData(Reader, Index);
    Check(ExtractedData(Reader, Reader.IndexOf('top/fraction.txt')) = 'fraction'#10,
      'tar.gz: every member in reverse order');
    Check(Reader.IndexOf('top') = Reader.IndexOf('top/'), 'IndexOf finds a folder without its /');
    Check(Reader.IndexOf('missing') = -1, 'IndexOf of a missing member');
  finally
    Reader.Free;
  end;
end;

function HasItem(const Items: TArchiveFolderItems; const Name: string; IsFolder: Boolean;
  Implied: Boolean): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 0 to High(Items) do
    if (Items[Index].Name = Name) and (Items[Index].IsFolder = IsFolder) and
      ((Items[Index].EntryIndex < 0) = Implied) then
      Exit(True);
end;

procedure TestFolders(const FixtureDirectory: string);
var
  Reader: TArchiveReader;
  Items: TArchiveFolderItems;
begin
  Reader := OpenArchive(FixtureDirectory + '/zip-deflated.zip');
  try
    Items := ListArchiveFolder(Reader, '');
    Check(Length(Items) = 5, Format('top folder has 5 items (got %d)', [Length(Items)]));
    Check(HasItem(Items, 'docs', True, False), 'top: docs, a folder member');
    Check(HasItem(Items, 'bin', True, True), 'top: bin, a folder only names make');
    Check(HasItem(Items, 'stamped.txt', False, False), 'top: stamped.txt, a file');
    Items := ListArchiveFolder(Reader, 'docs/');
    Check(Length(Items) = 3, Format('docs has 3 items (got %d)', [Length(Items)]));
    Check(HasItem(Items, 'readme.txt', False, False) and (Items[0].Path = 'docs/readme.txt'),
      'docs: readme.txt with its path');
    Items := ListArchiveFolder(Reader, 'data');
    Check(Length(Items) = 2, 'data (without /) has 2 items');
    Items := ListArchiveFolder(Reader, 'nothing');
    Check(Length(Items) = 0, 'a missing folder is empty');
  finally
    Reader.Free;
  end;
  Reader := OpenArchive(FixtureDirectory + '/zip-many.zip');
  try
    Items := ListArchiveFolder(Reader, '');
    Check((Length(Items) = 1) and (Items[0].Path = 'many/'), 'many: one implied folder');
    Items := ListArchiveFolder(Reader, 'many');
    Check(Length(Items) = 65540, 'many: all 65540 files in it');
  finally
    Reader.Free;
  end;
end;

procedure TestCancelling(const FixtureDirectory: string);
var
  Reader: TArchiveReader;
  Recorder: TProgressRecorder;
  Output: TMemoryStream;
  Cancelled: Boolean;
begin
  Reader := OpenArchive(FixtureDirectory + '/zip-deflated.zip');
  Recorder := TProgressRecorder.Create;
  Output := TMemoryStream.Create;
  try
    Reader.ExtractToStream(Reader.IndexOf('data/big.bin'), Output, @Recorder.Record_);
    Check(Recorder.LastBytes = 200000, 'progress reaches the size');
    Check(Recorder.Calls >= 2, 'progress is told more than once');
    Recorder.CancelAfter := 1;
    Cancelled := False;
    try
      Reader.ExtractToStream(Reader.IndexOf('data/big.bin'), Output, @Recorder.Record_);
    except
      on EArchiveCancelled do
        Cancelled := True;
    end;
    Check(Cancelled, 'cancelling stops extraction');
  finally
    Output.Free;
    Recorder.Free;
    Reader.Free;
  end;
end;

initialization
  OpenReaders := TStringList.Create;
finalization
  OpenReaders.Free;
end.
