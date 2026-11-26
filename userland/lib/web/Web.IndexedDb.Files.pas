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
  An origin's IndexedDB and Cache API storage on disk: one file per
  origin holding every database (its namespace, name, version, stores
  with their key generators, records and indexes with their entries)
  and whether the origin's storage is persistent. The file is written
  whole to a temporary file that then replaces the old one, so a crash
  leaves either the old or the new contents. Integers, doubles and
  byte strings as in Web.IndexedDb.Wire, after an 8-byte signature.
}
unit Web.IndexedDb.Files;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.IndexedDb.Database;

type
  { What one origin keeps. }
  TIdbOriginContents = record
    Persisted: Boolean;
    Databases: array of TIdbDatabase;
  end;

{ Writes Contents to FileName; False when the file could not be written. }
function SaveOriginFile(const FileName: string; constref Contents: TIdbOriginContents): Boolean;
{ Reads FileName: False (Contents empty) when it is missing or not a
  storage file. }
function LoadOriginFile(const FileName: string; out Contents: TIdbOriginContents): Boolean;

implementation

uses
  Web.IndexedDb.Wire,
  Web.IndexedDb.Keys,
  Web.IndexedDb.Entries;

const
  Signature: array[0..7] of Byte = (Ord('F'), Ord('P'), Ord('I'), Ord('D'), Ord('B'), 1, 0, 0);

procedure WriteList(Writer: TIdbWriter; List: TIdbEntryList; WithValues: Boolean);
var
  Position: Integer;
begin
  Writer.WriteLongWord(List.Count);
  for Position := 0 to List.Count - 1 do
  begin
    Writer.WriteBytes(List.Keys[Position]);
    if WithValues then
      Writer.WriteBytes(List.Values[Position]);
  end;
end;

procedure WriteDatabase(Writer: TIdbWriter; Database: TIdbDatabase);
var
  StorePosition, IndexPosition: Integer;
  Store: TIdbObjectStore;
  Index: TIdbIndex;
begin
  Writer.WriteByte(Database.Namespace);
  Writer.WriteRaw(Database.Name);
  Writer.WriteDouble(Database.Version);
  Writer.WriteLongWord(Database.NextStoreId);
  Writer.WriteLongWord(Database.StoreCount);
  for StorePosition := 0 to Database.StoreCount - 1 do
  begin
    Store := Database.Stores[StorePosition];
    Writer.WriteLongWord(Store.Id);
    Writer.WriteRaw(Store.Name);
    Writer.WriteBytes(Store.KeyPath);
    Writer.WriteBoolean(Store.AutoIncrement);
    Writer.WriteDouble(Store.Generator);
    Writer.WriteLongWord(Store.NextIndexId);
    WriteList(Writer, Store.Records, True);
    Writer.WriteLongWord(Store.IndexCount);
    for IndexPosition := 0 to Store.IndexCount - 1 do
    begin
      Index := Store.Indexes[IndexPosition];
      Writer.WriteLongWord(Index.Id);
      Writer.WriteRaw(Index.Name);
      Writer.WriteBytes(Index.KeyPath);
      Writer.WriteBoolean(Index.Unique);
      Writer.WriteBoolean(Index.MultiEntry);
      { The entries with their primary keys; the reverse list is made
        again from them. }
      WriteList(Writer, Index.Entries, True);
    end;
  end;
end;

function SaveOriginFile(const FileName: string; constref Contents: TIdbOriginContents): Boolean;
var
  Writer: TIdbWriter;
  Data: TBytes;
  Stream: TFileStream;
  Temporary: string;
  Position: Integer;
begin
  Result := False;
  Writer := TIdbWriter.Create;
  try
    for Position := 0 to High(Signature) do
      Writer.WriteByte(Signature[Position]);
    Writer.WriteBoolean(Contents.Persisted);
    Writer.WriteLongWord(Length(Contents.Databases));
    for Position := 0 to High(Contents.Databases) do
      WriteDatabase(Writer, Contents.Databases[Position]);
    Data := Writer.Data;
  finally
    Writer.Free;
  end;
  Temporary := FileName + '.new';
  try
    ForceDirectories(ExtractFileDir(FileName));
    Stream := TFileStream.Create(Temporary, fmCreate);
    try
      if Length(Data) > 0 then
        Stream.WriteBuffer(Data[0], Length(Data));
    finally
      Stream.Free;
    end;
    if FileExists(FileName) then
      DeleteFile(FileName);
    Result := RenameFile(Temporary, FileName);
  except
    on EStreamError do
      Result := False;
  end;
end;

procedure ReadList(Reader: TIdbReader; List: TIdbEntryList);
var
  Count, Position: LongWord;
  Key: TBytes;
begin
  Count := Reader.ReadLongWord;
  Position := 0;
  while Position < Count do
  begin
    Key := Reader.ReadBytes;
    List.RawAppend(Key, Reader.ReadBytes);
    Inc(Position);
  end;
end;

procedure RebuildReverse(Index: TIdbIndex);
var
  Position: Integer;
  PrimaryKey, IndexKey: TBytes;
begin
  for Position := 0 to Index.Entries.Count - 1 do
  begin
    PrimaryKey := Index.Entries.Values[Position];
    IndexKey := Copy(Index.Entries.Keys[Position], 0, Length(Index.Entries.Keys[Position]) - Length(PrimaryKey));
    Index.Reverse.RawPut(ConcatKeys(PrimaryKey, IndexKey), nil);
  end;
end;

function ReadDatabase(Reader: TIdbReader): TIdbDatabase;
var
  StoreCount, IndexCount, StorePosition, IndexPosition: LongWord;
  Store: TIdbObjectStore;
  Index: TIdbIndex;
begin
  Result := TIdbDatabase.Create;
  try
    Result.Namespace := Reader.ReadByte;
    Result.Name := Reader.ReadRaw;
    Result.Version := Trunc(Reader.ReadDouble);
    Result.NextStoreId := Reader.ReadLongWord;
    StoreCount := Reader.ReadLongWord;
    StorePosition := 0;
    while StorePosition < StoreCount do
    begin
      Store := TIdbObjectStore.Create;
      Result.InsertStore(-1, Store);
      Store.Id := Reader.ReadLongWord;
      Store.Name := Reader.ReadRaw;
      Store.KeyPath := Reader.ReadBytes;
      Store.AutoIncrement := Reader.ReadBoolean;
      Store.Generator := Reader.ReadDouble;
      Store.NextIndexId := Reader.ReadLongWord;
      ReadList(Reader, Store.Records);
      IndexCount := Reader.ReadLongWord;
      IndexPosition := 0;
      while IndexPosition < IndexCount do
      begin
        Index := TIdbIndex.Create;
        Store.InsertIndex(-1, Index);
        Result.AttachList(Index.Entries);
        Result.AttachList(Index.Reverse);
        Index.Id := Reader.ReadLongWord;
        Index.Name := Reader.ReadRaw;
        Index.KeyPath := Reader.ReadBytes;
        Index.Unique := Reader.ReadBoolean;
        Index.MultiEntry := Reader.ReadBoolean;
        ReadList(Reader, Index.Entries);
        RebuildReverse(Index);
        Inc(IndexPosition);
      end;
      Inc(StorePosition);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function LoadOriginFile(const FileName: string; out Contents: TIdbOriginContents): Boolean;
var
  Stream: TFileStream;
  Data: TBytes;
  Reader: TIdbReader;
  Count, Position: LongWord;
  Index: Integer;
begin
  Contents := Default(TIdbOriginContents);
  Result := False;
  if not FileExists(FileName) then
    Exit;
  Data := nil;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Data, Stream.Size);
      if Length(Data) > 0 then
        Stream.ReadBuffer(Data[0], Length(Data));
    finally
      Stream.Free;
    end;
  except
    on EStreamError do
      Exit;
  end;
  if Length(Data) < Length(Signature) then
    Exit;
  for Index := 0 to High(Signature) do
    if Data[Index] <> Signature[Index] then
      Exit;
  Reader := TIdbReader.Create(Copy(Data, Length(Signature), Length(Data) - Length(Signature)));
  try
    try
      Contents.Persisted := Reader.ReadBoolean;
      Count := Reader.ReadLongWord;
      Position := 0;
      while Position < Count do
      begin
        SetLength(Contents.Databases, Length(Contents.Databases) + 1);
        Contents.Databases[High(Contents.Databases)] := ReadDatabase(Reader);
        Inc(Position);
      end;
      Result := True;
    except
      on EIdbMalformed do
      begin
        for Index := 0 to High(Contents.Databases) do
          Contents.Databases[Index].Free;
        Contents := Default(TIdbOriginContents);
      end;
    end;
  finally
    Reader.Free;
  end;
end;

end.
