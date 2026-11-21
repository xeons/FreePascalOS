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
  The archive test's writing checks: zip files written with TZipWriter
  (folders, an empty file, a Unicode name, a big file, incompressible
  data, a link; once with ZIP64 forced; from files on disk; more than
  65535 members) are read back here, and listed in written-manifest.txt
  for check-written.py to check with Python's zipfile.
}
unit ArchiveTest.Writing;

{$mode objfpc}
{$H+}

interface

procedure TestWriting(const SampleDirectory, WorkDirectory: string);

implementation

uses
  Classes,
  SysUtils,
  StrUtils,
  TestChecks,
  Archive.Entries,
  Archive.Readers,
  Archive.ZipWriter,
  ArchiveTest.Support;

type
  TWrittenKind = (WrittenFile, WrittenFolder, WrittenLink);

  TWrittenMember = record
    Name: string;
    Kind: TWrittenKind;
    Data: string;
    ModificationTime: Int64;
    Mode: LongWord;
  end;

  TWrittenMembers = array of TWrittenMember;

const
  WrittenTime = 1700000123;
  ManyMembers = 65537;

var
  WrittenManifest: TStringList;

function Member(const Name: string; Kind: TWrittenKind; const Data: string; ModificationTime: Int64;
  Mode: LongWord): TWrittenMember;
begin
  Result.Name := Name;
  Result.Kind := Kind;
  Result.Data := Data;
  Result.ModificationTime := ModificationTime;
  Result.Mode := Mode;
end;

function KindLetter(Kind: TWrittenKind): string;
begin
  case Kind of
    WrittenFolder: Result := 'd';
    WrittenLink: Result := 'l';
  else
    Result := 'f';
  end;
end;

procedure NoteMembers(const Archive: string; const Members: TWrittenMembers);
var
  Index: Integer;
begin
  for Index := 0 to High(Members) do
    WrittenManifest.Add(Format('entry'#9'%s'#9'%s'#9'%s'#9'%d'#9'%s'#9'%d'#9'%s',
      [Archive, Members[Index].Name, KindLetter(Members[Index].Kind), Length(Members[Index].Data),
       CrcHex(Members[Index].Data), Members[Index].ModificationTime, OctalText(Members[Index].Mode)]));
  WrittenManifest.Add(Format('count'#9'%s'#9'%d', [Archive, Length(Members)]));
end;

{ Reads the written zip back and compares it with what went in. }
procedure CheckReadBack(const Path: string; const Members: TWrittenMembers);
var
  Reader: TArchiveReader;
  Index, Found: Integer;
  Entry: TArchiveEntry;
  Prefix: string;
begin
  Reader := OpenArchive(Path);
  try
    Check(Reader.Count = Length(Members), ExtractFileName(Path) + ': member count read back');
    for Index := 0 to High(Members) do
    begin
      Prefix := ExtractFileName(Path) + ' ' + Members[Index].Name + ': ';
      Found := Reader.IndexOf(Members[Index].Name);
      Check(Found = Index, Prefix + 'read back in order');
      if Found < 0 then
        Continue;
      Entry := Reader[Found];
      Check(Entry.IsFolder = (Members[Index].Kind = WrittenFolder), Prefix + 'folder or not');
      Check(Entry.IsLink = (Members[Index].Kind = WrittenLink), Prefix + 'link or not');
      Check(Entry.ModificationTime = Members[Index].ModificationTime, Prefix + 'time');
      Check(Entry.Mode = Members[Index].Mode, Prefix + Format('mode %s (got %s)', [OctalText(Members[Index].Mode), OctalText(Entry.Mode)]));
      if Members[Index].Kind = WrittenFolder then
        Continue;
      Check(Entry.Size = QWord(Length(Members[Index].Data)), Prefix + 'size');
      Check(ExtractedData(Reader, Found) = Members[Index].Data, Prefix + 'data');
      if Members[Index].Kind = WrittenLink then
        Check(Entry.LinkTarget = Members[Index].Data, Prefix + 'link target');
    end;
  finally
    Reader.Free;
  end;
end;

function StandardMembers: TWrittenMembers;
begin
  Result := nil;
  SetLength(Result, 9);
  Result[0] := Member('folder/', WrittenFolder, '', WrittenTime, ModeDefaultFolder);
  Result[1] := Member('folder/private/', WrittenFolder, '', WrittenTime, ModeFolder or &700);
  Result[2] := Member('folder/hello.txt', WrittenFile, DupeString('hello, zip'#10, 100), WrittenTime,
    ModeRegularFile or &644);
  Result[3] := Member('folder/empty.txt', WrittenFile, '', WrittenTime, ModeDefaultFile);
  Result[4] := Member('unicode/gr'#$C3#$BC#$C3#$9F'e '#$E6#$97#$A5#$E6#$9C#$AC'.txt', WrittenFile,
    'Gr'#$C3#$BC#$C3#$9F'e'#10, WrittenTime, ModeRegularFile or &755);
  Result[5] := Member('big/mixed.bin', WrittenFile, MixedData(300000, 17), WrittenTime, ModeRegularFile or &600);
  Result[6] := Member('big/random.bin', WrittenFile, RandomData(100000, 23), WrittenTime, ModeDefaultFile);
  Result[7] := Member('folder/link', WrittenLink, 'hello.txt', WrittenTime, ModeDefaultLink);
  Result[8] := Member('old.txt', WrittenFile, 'from 1975', 170000000, ModeDefaultFile);
end;

procedure WriteMembers(Writer: TZipWriter; const Members: TWrittenMembers; Recorder: TProgressRecorder);
var
  Index: Integer;
  Source: TStringStream;
begin
  for Index := 0 to High(Members) do
    case Members[Index].Kind of
      WrittenFolder:
        Writer.AddFolder(Members[Index].Name, Members[Index].ModificationTime, Members[Index].Mode and &7777);
      WrittenLink:
        Writer.AddLink(Members[Index].Name, Members[Index].Data, Members[Index].ModificationTime);
    else
      begin
        Source := TStringStream.Create(Members[Index].Data);
        try
          { Permission bits alone (the type is added), or 0 for the default. }
          if Members[Index].Mode = ModeDefaultFile then
            Writer.AddStream(Source, Members[Index].Name, Members[Index].ModificationTime, 0, @Recorder.Record_)
          else
            Writer.AddStream(Source, Members[Index].Name, Members[Index].ModificationTime,
              Members[Index].Mode and &7777, @Recorder.Record_);
        finally
          Source.Free;
        end;
      end;
    end;
end;

procedure WriteStandard(const Path: string; ForceZip64: Boolean);
var
  Writer: TZipWriter;
  Recorder: TProgressRecorder;
  Members: TWrittenMembers;
  Reader: TArchiveReader;
begin
  Members := StandardMembers;
  Recorder := TProgressRecorder.Create;
  try
    Writer := TZipWriter.Create(Path);
    try
      Writer.ForceZip64 := ForceZip64;
      WriteMembers(Writer, Members, Recorder);
      Writer.Finish;
    finally
      Writer.Free;
    end;
    Check(Recorder.LastBytes = 9, ExtractFileName(Path) + ': progress counted the last member');
  finally
    Recorder.Free;
  end;
  CheckReadBack(Path, Members);
  NoteMembers(ExtractFileName(Path), Members);
  if ForceZip64 then
    WrittenManifest.Add('zip64'#9 + ExtractFileName(Path));
  Reader := OpenArchive(Path);
  try
    Check(Reader[Reader.IndexOf('big/random.bin')].Method = MethodStored,
      ExtractFileName(Path) + ': incompressible data is stored');
    Check(Reader[Reader.IndexOf('big/mixed.bin')].Method = MethodDeflated,
      ExtractFileName(Path) + ': compressible data is deflated');
    Check(Reader[Reader.IndexOf('big/mixed.bin')].CompressedSize < 300000,
      ExtractFileName(Path) + ': deflate made it smaller');
  finally
    Reader.Free;
  end;
end;

procedure WriteFromFiles(const Path, WorkDirectory: string);
var
  Writer: TZipWriter;
  Source: string;
  Members: TWrittenMembers;
begin
  Source := WorkDirectory + '/extracted';
  Members := nil;
  SetLength(Members, 3);
  Members[0] := Member('docs/', WrittenFolder, '', 1715953530, ModeFolder or &755);
  Members[1] := Member('docs/readme.txt', WrittenFile, DupeString('Hello from the archive test.'#10, 20),
    1715953530, ModeRegularFile or &644);
  Members[2] := Member('run.sh', WrittenFile, '#!/bin/sh'#10'echo run'#10, 1715953530, ModeRegularFile or &755);
  Writer := TZipWriter.Create(Path);
  try
    Writer.AddFile(Source + '/docs', 'docs');
    Writer.AddFile(Source + '/docs/readme.txt', 'docs/readme.txt');
    Writer.AddFile(Source + '/bin/run.sh', 'run.sh');
    Writer.Finish;
  finally
    Writer.Free;
  end;
  CheckReadBack(Path, Members);
  NoteMembers(ExtractFileName(Path), Members);
end;

procedure WriteMany(const Path: string);
var
  Writer: TZipWriter;
  Source: TStringStream;
  Index: Integer;
  Reader: TArchiveReader;
begin
  Writer := TZipWriter.Create(Path);
  try
    Writer.CompressionLevel := 0;
    for Index := 0 to ManyMembers - 1 do
    begin
      Source := TStringStream.Create(IntToStr(Index));
      try
        Writer.AddStream(Source, Format('many/%05d', [Index]), WrittenTime, 0);
      finally
        Source.Free;
      end;
    end;
    Writer.Finish;
  finally
    Writer.Free;
  end;
  Reader := OpenArchive(Path);
  try
    Check(Reader.Count = ManyMembers, 'written-many.zip: all members read back (ZIP64 end record)');
    Check(ExtractedData(Reader, Reader.IndexOf('many/65536')) = '65536', 'written-many.zip: the last member');
  finally
    Reader.Free;
  end;
  WrittenManifest.Add(Format('count'#9'%s'#9'%d', [ExtractFileName(Path), ManyMembers]));
  WrittenManifest.Add('zip64'#9 + ExtractFileName(Path));
end;

procedure WriteUnfinished(const Path: string);
var
  Writer: TZipWriter;
  Source: TStringStream;
begin
  Writer := TZipWriter.Create(Path);
  try
    Source := TStringStream.Create('never finished');
    try
      Writer.AddStream(Source, 'a.txt', WrittenTime, 0);
    finally
      Source.Free;
    end;
  finally
    Writer.Free;
  end;
  try
    OpenArchive(Path).Free;
    Check(False, 'an unfinished zip cannot be opened');
  except
    on EArchiveError do
      Check(True, 'an unfinished zip cannot be opened');
  end;
  DeleteFile(Path);
end;

procedure TestWriting(const SampleDirectory, WorkDirectory: string);
begin
  ForceDirectories(SampleDirectory);
  WrittenManifest := TStringList.Create;
  try
    try
      WriteStandard(SampleDirectory + '/written-normal.zip', False);
      WriteStandard(SampleDirectory + '/written-zip64.zip', True);
      WriteFromFiles(SampleDirectory + '/written-files.zip', WorkDirectory);
      WriteMany(SampleDirectory + '/written-many.zip');
      WriteUnfinished(WorkDirectory + '/unfinished.zip');
    except
      on Error: Exception do
        Check(False, 'writing: ' + Error.ClassName + ': ' + Error.Message);
    end;
    WrittenManifest.SaveToFile(SampleDirectory + '/written-manifest.txt');
  finally
    WrittenManifest.Free;
  end;
end;

end.
