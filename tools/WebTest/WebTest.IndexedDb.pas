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
  The IndexedDB storage service without a page: key bytes and their
  order, the sorted entry lists, a database written to its origin's file
  and read back by a new service (committed changes only), abort
  undoing records and schema, a database an aborted upgrade made being
  removed, requests naming another client's transaction or cut short
  being refused.
}
unit WebTest.IndexedDb;

{$mode objfpc}
{$H+}

interface

procedure RunIndexedDbTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.IndexedDb.Keys,
  Web.IndexedDb.Entries,
  Web.IndexedDb.Wire,
  Web.IndexedDb.Service;

type
  TQuietClient = class(TIndexedDbClient)
  public
    Notices: Integer;
    procedure Notice(const Payload: TBytes); override;
  end;

procedure TQuietClient.Notice(const Payload: TBytes);
begin
  Inc(Notices);
end;

const
  Origin = 'https://store.test';

function Bytes(const Text: RawByteString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Result[0], Length(Text));
end;

procedure CheckKeys;
var
  Value: Double;
  Successor: TBytes;
begin
  Check((CompareKeyBytes(NumberKey(-1e300), NumberKey(-1)) < 0) and (CompareKeyBytes(NumberKey(-1), NumberKey(0)) < 0)
    and (CompareKeyBytes(NumberKey(0), NumberKey(0.5)) < 0) and (CompareKeyBytes(NumberKey(0.5), NumberKey(7)) < 0),
    'indexeddb: number keys sort by value');
  Check(CompareKeyBytes(NumberKey(-0.0), NumberKey(0)) = 0, 'indexeddb: -0 is 0');
  Check(KeyNumberValue(NumberKey(-12.25), Value) and (Value = -12.25) and not KeyNumberValue(Bytes('0a'#0), Value),
    'indexeddb: a number key reads back');
  Check(PrefixSuccessor(Bytes('ab'#255), Successor) and (CompareKeyBytes(Successor, Bytes('ac')) = 0) and
    not PrefixSuccessor(Bytes(#255#255), Successor), 'indexeddb: prefix successors');
end;

procedure CheckEntries;
var
  List: TIdbEntryList;
  Range: TIdbKeyRange;
  First, Past, Index: Integer;
begin
  List := TIdbEntryList.Create;
  try
    for Index := 9 downto 1 do
      List.Put(NumberKey(Index), Bytes(IntToStr(Index)));
    List.Put(NumberKey(5), Bytes('five'));
    Check((List.Count = 9) and (CompareKeyBytes(List.Values[4], Bytes('five')) = 0), 'indexeddb: entries sorted, ' +
      'replaced');
    Range := UnboundedRange;
    Range.HasLower := True;
    Range.Lower := NumberKey(3);
    Range.LowerOpen := True;
    Range.HasUpper := True;
    Range.Upper := NumberKey(6);
    List.RangeBounds(Range, First, Past);
    Check((First = 3) and (Past = 6), 'indexeddb: an open lower bound, a closed upper bound');
    List.Remove(NumberKey(4));
    List.RangeBounds(Range, First, Past);
    Check((List.Count = 8) and (Past - First = 2), 'indexeddb: a removed entry');
  finally
    List.Free;
  end;
end;

{ ---- requests ---- }

function Call(Service: TIndexedDbService; Client: TIndexedDbClient; Writer: TIdbWriter; out Reader: TIdbReader): Byte;
var
  Reply: TIdbReader;
begin
  Reply := TIdbReader.Create(Service.Execute(Client, Origin, Writer.Data));
  Writer.Free;
  try
    Result := Reply.ReadByte;
    if Result = IdbStatusOk then
      Reader := TIdbReader.Create(Reply.ReadBytes)
    else
      Reader := nil;
  finally
    Reply.Free;
  end;
end;

function Request(Operation: Byte): TIdbWriter;
begin
  Result := TIdbWriter.Create;
  Result.WriteByte(Operation);
end;

procedure WriteOnlyRange(Writer: TIdbWriter; const Key: TBytes);
begin
  Writer.WriteByte(3);
  Writer.WriteBytes(Key);
  Writer.WriteBytes(Key);
end;

{ Opens database 'db' at Version: the outcome, the connection and (an
  upgrade) its transaction. }
function OpenDatabase(Service: TIndexedDbService; Client: TIndexedDbClient; Version: Double;
  out Connection, Transaction: LongWord): Byte;
var
  Writer: TIdbWriter;
  Reader: TIdbReader;
begin
  Connection := 0;
  Transaction := 0;
  Writer := Request(IdbOpOpen);
  Writer.WriteByte(0);
  Writer.WriteRaw('d'#0'b'#0);
  Writer.WriteDouble(Version);
  Writer.WriteLongWord(1);
  if Call(Service, Client, Writer, Reader) <> IdbStatusOk then
    Exit(0);
  try
    Result := Reader.ReadByte;
    if Result = IdbOutcomeWait then
      Exit;
    Connection := Reader.ReadLongWord;
    if Result = IdbOutcomeUpgrade then
      Transaction := Reader.ReadLongWord;
  finally
    Reader.Free;
  end;
end;

function Simple(Service: TIndexedDbService; Client: TIndexedDbClient; Writer: TIdbWriter): Byte;
var
  Reader: TIdbReader;
begin
  Result := Call(Service, Client, Writer, Reader);
  Reader.Free;
end;

function CreateStore(Service: TIndexedDbService; Client: TIndexedDbClient; Transaction: LongWord): LongWord;
var
  Writer: TIdbWriter;
  Reader: TIdbReader;
begin
  Result := 0;
  Writer := Request(IdbOpCreateStore);
  Writer.WriteLongWord(Transaction);
  Writer.WriteRaw('s'#0);
  Writer.WriteBytes(Bytes(#0));
  Writer.WriteBoolean(False);
  if Call(Service, Client, Writer, Reader) = IdbStatusOk then
  begin
    Result := Reader.ReadLongWord;
    Reader.Free;
  end;
end;

function Put(Service: TIndexedDbService; Client: TIndexedDbClient; Transaction, Store: LongWord; Key: Double;
  const Value: RawByteString): Byte;
var
  Writer: TIdbWriter;
begin
  Writer := Request(IdbOpPut);
  Writer.WriteLongWord(Transaction);
  Writer.WriteLongWord(Store);
  Writer.WriteByte(0);
  Writer.WriteBytes(NumberKey(Key));
  Writer.WriteBytes(Bytes(Value));
  Writer.WriteLongWord(0);
  Result := Simple(Service, Client, Writer);
end;

function Finish(Service: TIndexedDbService; Client: TIndexedDbClient; Transaction: LongWord; Commit: Boolean): Byte;
var
  Writer: TIdbWriter;
begin
  if Commit then
    Writer := Request(IdbOpCommit)
  else
    Writer := Request(IdbOpAbort);
  Writer.WriteLongWord(Transaction);
  Result := Simple(Service, Client, Writer);
end;

function BeginTransaction(Service: TIndexedDbService; Client: TIndexedDbClient; Connection, Store: LongWord;
  Mode: Byte): LongWord;
var
  Writer: TIdbWriter;
  Reader: TIdbReader;
begin
  Result := 0;
  Writer := Request(IdbOpBegin);
  Writer.WriteLongWord(Connection);
  Writer.WriteByte(Mode);
  Writer.WriteLongWord(1);
  Writer.WriteLongWord(Store);
  if Call(Service, Client, Writer, Reader) <> IdbStatusOk then
    Exit;
  if Reader.ReadByte = IdbOutcomeDone then
    Result := Reader.ReadLongWord;
  Reader.Free;
end;

{ The value of Key ('' when there is none, '!' on failure). }
function Get(Service: TIndexedDbService; Client: TIndexedDbClient; Transaction, Store: LongWord; Key: Double): string;
var
  Writer: TIdbWriter;
  Reader: TIdbReader;
  Value: TBytes;
begin
  Writer := Request(IdbOpGet);
  Writer.WriteLongWord(Transaction);
  Writer.WriteLongWord(Store);
  Writer.WriteLongWord(0);
  WriteOnlyRange(Writer, NumberKey(Key));
  Writer.WriteByte(0);
  if Call(Service, Client, Writer, Reader) <> IdbStatusOk then
    Exit('!');
  try
    if not Reader.ReadBoolean then
      Exit('');
    Reader.ReadBytes;
    Reader.ReadBytes;
    Value := Reader.ReadBytes;
    SetLength(Result, Length(Value));
    if Length(Value) > 0 then
      Move(Value[0], Result[1], Length(Value));
  finally
    Reader.Free;
  end;
end;

procedure CheckService(const Folder: string);
var
  Service: TIndexedDbService;
  Client, Stranger: TQuietClient;
  Connection, Transaction, Store: LongWord;
  Outcome: Byte;
  Malformed: TIdbWriter;
begin
  Client := TQuietClient.Create;
  Stranger := TQuietClient.Create;
  Service := TIndexedDbService.Create(Folder);
  try
    Outcome := OpenDatabase(Service, Client, 1, Connection, Transaction);
    Check(Outcome = IdbOutcomeUpgrade, 'indexeddb: a new database is upgraded');
    Store := CreateStore(Service, Client, Transaction);
    Check((Store <> 0) and (Put(Service, Client, Transaction, Store, 1, 'one') = IdbStatusOk),
      'indexeddb: a store and a record in the upgrade');
    Check(Put(Service, Stranger, Transaction, Store, 9, 'x') = IdbStatusAbort, 'indexeddb: another client''s ' +
      'transaction is refused');
    Check(Finish(Service, Client, Transaction, True) = IdbStatusOk, 'indexeddb: the upgrade commits');
    Transaction := BeginTransaction(Service, Client, Connection, Store, TransactionReadWrite);
    Put(Service, Client, Transaction, Store, 2, 'two');
    Finish(Service, Client, Transaction, False);
    Transaction := BeginTransaction(Service, Client, Connection, Store, TransactionReadWrite);
    Check((Get(Service, Client, Transaction, Store, 2) = '') and (Get(Service, Client, Transaction, Store, 1) = 'one'),
      'indexeddb: abort undoes a record');
    Put(Service, Client, Transaction, Store, 3, 'three');
    Check(BeginTransaction(Service, Stranger, Connection, Store, TransactionReadOnly) = 0,
      'indexeddb: another client''s connection is refused');
    Finish(Service, Client, Transaction, True);
    { Uncommitted at the end: not kept. }
    Transaction := BeginTransaction(Service, Client, Connection, Store, TransactionReadWrite);
    Put(Service, Client, Transaction, Store, 4, 'four');
    Service.SaveAll;
    Malformed := Request(IdbOpPut);
    Check(Simple(Service, Client, Malformed) = IdbStatusUnknown, 'indexeddb: a request cut short is refused');
  finally
    Service.Free;
  end;
  Check(FileExists(IncludeTrailingPathDelimiter(Folder) + OriginStorageFileName(Origin)),
    'indexeddb: the origin''s file is written');
  Service := TIndexedDbService.Create(Folder);
  try
    Outcome := OpenDatabase(Service, Client, 0, Connection, Transaction);
    Check(Outcome = IdbOutcomeDone, 'indexeddb: the database is read back at its version');
    Transaction := BeginTransaction(Service, Client, Connection, Store, TransactionReadOnly);
    Check((Get(Service, Client, Transaction, Store, 1) = 'one') and (Get(Service, Client, Transaction, Store, 3) =
      'three') and (Get(Service, Client, Transaction, Store, 4) = ''), 'indexeddb: committed records only come back');
    Finish(Service, Client, Transaction, True);
    Check(Service.Usage(Origin) > 0, 'indexeddb: usage counts the records');
    Service.ClientClosed(Client);
    { An aborted upgrade of a database it made removes it. }
    Outcome := OpenDatabase(Service, Stranger, 5, Connection, Transaction);
    Check(Outcome = IdbOutcomeUpgrade, 'indexeddb: a version change');
    Finish(Service, Stranger, Transaction, False);
    Service.ClientClosed(Stranger);
    Outcome := OpenDatabase(Service, Client, 0, Connection, Transaction);
    Check(Outcome = IdbOutcomeDone, 'indexeddb: an aborted version change keeps the old version');
    Service.ClearAll;
    Check(not FileExists(IncludeTrailingPathDelimiter(Folder) + OriginStorageFileName(Origin)) and
      (Client.Notices > 0), 'indexeddb: clearing removes the files and closes connections');
  finally
    Service.Free;
    Client.Free;
    Stranger.Free;
  end;
end;

procedure RunIndexedDbTests;
var
  Folder: string;
begin
  CheckKeys;
  CheckEntries;
  Folder := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'webtest-indexeddb-' + IntToStr(GetProcessID);
  try
    CheckService(Folder);
  finally
    DeleteFile(IncludeTrailingPathDelimiter(Folder) + OriginStorageFileName(Origin));
    RemoveDir(Folder);
  end;
end;

end.
