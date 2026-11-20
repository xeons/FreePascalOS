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
  htmldump - parse an HTML file with libweb and print its tree

  htmldump [-s] [-e] [-c CHARSET] [-f CONTEXT] FILE

  Prints the document tree in the html5lib test format ("| <html>"
  lines). -s prints the document serialized again instead, -e adds the
  parse errors, -c gives the transport layer charset (as a Content-Type
  header would), -f parses the file as a fragment in the context of an
  HTML element named CONTEXT (as innerHTML does).
}
program htmldump;

{$mode objfpc}{$H+}

uses
  Classes,
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.Encoding.Labels,
  Web.Encoding.Sniffing,
  Web.Encoding.DecoderFactory,
  Web.Dom,
  Web.Html.Parser,
  Web.Html.Serializer,
  Web.Html.TreeDump;

const
  Usage = 'Usage: htmldump [-s] [-e] [-c CHARSET] [-f CONTEXT] FILE'#10 +
    'Parse an HTML file and print its tree in the html5lib test format.'#10 +
    #10 +
    '  -s          print the document serialized as HTML instead'#10 +
    '  -e          print the parse errors too'#10 +
    '  -c CHARSET  the transport layer character encoding'#10 +
    '  -f CONTEXT  parse as a fragment in an HTML CONTEXT element'#10;

var
  Serialize: Boolean = False;
  ShowErrors: Boolean = False;
  TransportCharset: string = '';
  ContextName: string = '';
  FileName: string = '';

function ReadWholeFile(const Name: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(Name, fmOpenRead);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

function ParseArguments: Boolean;
var
  Index: Integer;
  Argument: string;
begin
  Result := False;
  Index := 1;
  while Index <= ParamCount do
  begin
    Argument := ParamStr(Index);
    if Argument = '-s' then
      Serialize := True
    else if Argument = '-e' then
      ShowErrors := True
    else if (Argument = '-c') and (Index < ParamCount) then
    begin
      Inc(Index);
      TransportCharset := ParamStr(Index);
    end
    else if (Argument = '-f') and (Index < ParamCount) then
    begin
      Inc(Index);
      ContextName := ParamStr(Index);
    end
    else if (Argument <> '') and (Argument[1] = '-') then
      Exit
    else if FileName = '' then
      FileName := Argument
    else
      Exit;
    Inc(Index);
  end;
  Result := FileName <> '';
end;

procedure PrintErrors(Parser: THtmlParser);
var
  Index: Integer;
begin
  WriteLn('#errors ', Parser.ErrorCount);
  for Index := 1 to Parser.ErrorCodes.Count do
    WriteLn(Parser.ErrorCodes[Index - 1]);
end;

procedure DumpDocument(const Bytes: string);
var
  Document: TDocument;
  Parser: THtmlParser;
  Restart: TTextEncoding;
begin
  Document := TDocument.CreateDocument(True);
  try
    Parser := THtmlParser.Create(Document);
    try
      Parser.CollectErrors := ShowErrors;
      Parser.SetTransportCharset(TransportCharset);
      Parser.WriteByteString(Bytes);
      Parser.Finish;
      if Parser.RestartRequested then
      begin
        { A meta charset changed the encoding: parse again with it. }
        Restart := Parser.RestartEncoding;
        FreeAndNil(Parser);
        Document.Release;
        Document := TDocument.CreateDocument(True);
        Parser := THtmlParser.Create(Document);
        Parser.CollectErrors := ShowErrors;
        Parser.SetEncoding(Restart, ConfidenceCertain);
        Parser.WriteByteString(Bytes);
        Parser.Finish;
      end;
      if Parser.UnsupportedEncoding then
        WriteLn(StdErr, 'htmldump: ', EncodingName(Parser.Encoding), ' is not supported yet, read as windows-1252');
      if Serialize then
        Write(SerializeChildren(Document))
      else
        Write(DumpTree(Document));
      if ShowErrors then
        PrintErrors(Parser);
    finally
      Parser.Free;
    end;
  finally
    Document.Release;
  end;
end;

procedure DumpFragment(const Bytes: string);
var
  Document: TDocument;
  Context: TElement;
  Fragment: TDocumentFragment;
begin
  Document := TDocument.CreateDocument(True);
  try
    Context := Document.CreateElement(ContextName);
    Fragment := ParseHtmlFragment(Context, DecodeBytes(Bytes, TextEncodingUtf8));
    if Serialize then
      Write(SerializeChildren(Fragment))
    else
      Write(DumpTree(Fragment));
  finally
    Document.Release;
  end;
end;

var
  Bytes: string;
begin
  if not ParseArguments then
  begin
    Write(StdErr, Usage);
    Halt(2);
  end;
  try
    Bytes := ReadWholeFile(FileName);
  except
    on Error: Exception do
    begin
      WriteLn(StdErr, 'htmldump: ', FileName, ': ', Error.Message);
      Halt(1);
    end;
  end;
  if ContextName <> '' then
    DumpFragment(Bytes)
  else
    DumpDocument(Bytes);
end.
