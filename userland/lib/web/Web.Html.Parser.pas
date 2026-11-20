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
  The HTML parser: bytes in (any number of pieces), a document out.

  - Encoding: the first bytes (1024, or all there are when the input
    ends sooner) are sniffed (BOM, the transport charset, the meta
    prescan, windows-1252); a decoder makes UTF-8 for the input stream.
    A meta charset met later while the confidence is tentative changes
    the decoder at once if everything so far was ASCII, and otherwise
    asks for a restart (RestartEncoding), which ParseHtmlDocument does.
  - Scripts (phase 2): at a script end tag the parser calls its script
    host, with the insertion point set just before the next input
    character and the script nesting level raised. When the host says a
    parsing-blocking script is pending the parser pauses (the tokenizer
    stops); Resume carries on. DocumentWrite inserts text at the
    insertion point and tokenizes it at once, up to the insertion point,
    unless the parser is paused.
  - The fragment parsing algorithm (innerHTML and friends) is
    ParseHtmlFragment.
}
unit Web.Html.Parser;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.Atoms,
  Web.TextBuffers,
  Web.Encoding.Labels,
  Web.Encoding.Decoders,
  Web.Encoding.Sniffing,
  Web.Dom,
  Web.Html.Tokens,
  Web.Html.InputStream,
  Web.Html.Tokenizer,
  Web.Html.TreeBuilder;

type
  THtmlParser = class;

  { Runs scripts for the parser (the script bindings, phase 2). }
  TScriptHost = class
  public
    { The parser met the end of Script. True when a parsing-blocking
      script is now pending: the parser pauses until Resume. }
    function ScriptEndTagReached(Parser: THtmlParser; Script: TElement): Boolean; virtual; abstract;
  end;

  THtmlParser = class
  private
    FDocument: TDocument;
    FInput: THtmlInputStream;
    FTokenizer: THtmlTokenizer;
    FTreeBuilder: THtmlTreeBuilder;
    FDecoder: TTextDecoder;
    FDecoded: TTextBuffer;
    FPendingBytes: string;
    FTransportCharset: string;
    FEncoding: TTextEncoding;
    FConfidence: TEncodingConfidence;
    FEncodingDecided: Boolean;
    FAllAsciiSoFar: Boolean;
    FRestartRequested: Boolean;
    FRestartEncoding: TTextEncoding;
    FFinished: Boolean;
    FEnded: Boolean;
    FPaused: Boolean;
    FScriptNestingLevel: Integer;
    FScriptHost: TScriptHost;
    FErrorCodes: TStringList;
    FCollectErrors: Boolean;
    FUnsupportedEncoding: Boolean;
    procedure DecideEncoding;
    function TransportCharsetKnown: Boolean;
    procedure DecodeIntoInput(Bytes: PByte; Count: SizeInt; Flush: Boolean);
    procedure Pump;
    procedure HandleScriptEnd(Script: TElement);
    procedure HandleEncodingDeclared(const Value: string; FromContent: Boolean);
    procedure HandleParseError(const Code: string);
    function GetErrorCount: SizeInt;
    function GetScriptingEnabled: Boolean;
    procedure SetScriptingEnabled(Value: Boolean);
  public
    { Parses into Document (which the caller keeps). }
    constructor Create(Document: TDocument);
    destructor Destroy; override;
    { The Content-Type charset, before the first bytes. }
    procedure SetTransportCharset(const LabelText: string);
    { Decides the encoding instead of sniffing (before the first bytes). }
    procedure SetEncoding(NewEncoding: TTextEncoding; NewConfidence: TEncodingConfidence);
    procedure WriteBytes(Bytes: PByte; Count: SizeInt);
    procedure WriteByteString(const Bytes: string);
    { Text already decoded (UTF-8): the encoding is irrelevant then. }
    procedure WriteText(const Text: string);
    { The end of the input. }
    procedure Finish;
    { document.write: inserts Text at the insertion point. }
    procedure DocumentWrite(const Text: string);
    { Carries on after a parsing-blocking script. }
    procedure Resume;
    property Document: TDocument read FDocument;
    property TreeBuilder: THtmlTreeBuilder read FTreeBuilder;
    property Tokenizer: THtmlTokenizer read FTokenizer;
    property ScriptHost: TScriptHost read FScriptHost write FScriptHost;
    property ScriptingEnabled: Boolean read GetScriptingEnabled write SetScriptingEnabled;
    property Paused: Boolean read FPaused;
    property ScriptNestingLevel: Integer read FScriptNestingLevel;
    property Encoding: TTextEncoding read FEncoding;
    property Confidence: TEncodingConfidence read FConfidence;
    { A meta element named an encoding that changes what was decoded: the
      document should be parsed again with RestartEncoding. }
    property RestartRequested: Boolean read FRestartRequested;
    property RestartEncoding: TTextEncoding read FRestartEncoding;
    { The encoding has no decoder yet (CJK): windows-1252 was used. }
    property UnsupportedEncoding: Boolean read FUnsupportedEncoding;
    property ErrorCount: SizeInt read GetErrorCount;
    { With CollectErrors, the parse error codes in order. }
    property CollectErrors: Boolean read FCollectErrors write FCollectErrors;
    property ErrorCodes: TStringList read FErrorCodes;
    property Ended: Boolean read FEnded;
    { The encoding is known and bytes are being decoded. }
    property EncodingDecided: Boolean read FEncodingDecided;
  end;

{ Parses a whole document from bytes: sniffing, and a restart when a meta
  charset changes the encoding. The caller releases the document. }
function ParseHtmlDocument(const Bytes: string; const TransportCharset: string = ''): TDocument;
{ Parses a document from text already decoded (UTF-8). }
function ParseHtmlText(const Text: string; ScriptingEnabled: Boolean = False): TDocument;
{ The HTML fragment parsing algorithm: the nodes Text parses into in the
  context of Context, in a new fragment of Context's document. }
function ParseHtmlFragment(Context: TElement; const Text: string): TDocumentFragment;

implementation

uses
  Web.Encoding.DecoderFactory;

constructor THtmlParser.Create(Document: TDocument);
begin
  inherited Create;
  FDocument := Document;
  FInput := THtmlInputStream.Create;
  FTreeBuilder := THtmlTreeBuilder.Create(Document);
  FTokenizer := THtmlTokenizer.Create(FInput, FTreeBuilder);
  FTreeBuilder.Tokenizer := FTokenizer;
  FTreeBuilder.OnScriptEnd := @HandleScriptEnd;
  FTreeBuilder.OnEncodingDeclared := @HandleEncodingDeclared;
  FTreeBuilder.ScriptingEnabled := Document.ScriptingEnabled;
  FTokenizer.OnParseError := @HandleParseError;
  FTreeBuilder.OnParseError := @HandleParseError;
  FDecoded := TTextBuffer.Create;
  FErrorCodes := TStringList.Create;
  FAllAsciiSoFar := True;
  FEncoding := TextEncodingUtf8;
  FConfidence := ConfidenceTentative;
end;

destructor THtmlParser.Destroy;
begin
  FTokenizer.Free;
  FTreeBuilder.Free;
  FInput.Free;
  FDecoder.Free;
  FDecoded.Free;
  FErrorCodes.Free;
  inherited Destroy;
end;

function THtmlParser.GetScriptingEnabled: Boolean;
begin
  Result := FTreeBuilder.ScriptingEnabled;
end;

procedure THtmlParser.SetScriptingEnabled(Value: Boolean);
begin
  FTreeBuilder.ScriptingEnabled := Value;
end;

function THtmlParser.GetErrorCount: SizeInt;
begin
  Result := FTokenizer.ErrorCount + FTreeBuilder.ErrorCount + FInput.PreprocessingErrors;
end;

procedure THtmlParser.HandleParseError(const Code: string);
begin
  if FCollectErrors then
    FErrorCodes.Add(Code);
end;

procedure THtmlParser.SetTransportCharset(const LabelText: string);
begin
  FTransportCharset := LabelText;
end;

procedure THtmlParser.SetEncoding(NewEncoding: TTextEncoding; NewConfidence: TEncodingConfidence);
begin
  FEncoding := NewEncoding;
  FConfidence := NewConfidence;
  FDecoder.Free;
  FDecoder := CreateDecoder(NewEncoding);
  if FDecoder = nil then
  begin
    FUnsupportedEncoding := True;
    FDecoder := CreateDecoder(TextEncodingWindows1252);
  end;
  FEncodingDecided := True;
  FDocument.CharacterSet := EncodingName(NewEncoding);
end;

procedure THtmlParser.DecideEncoding;
var
  MarkLength: Integer;
  Sniffed: TTextEncoding;
  SniffedConfidence: TEncodingConfidence;
begin
  Sniffed := SniffHtmlEncoding(PByte(PChar(FPendingBytes)), Length(FPendingBytes), FTransportCharset,
    SniffedConfidence, MarkLength);
  SetEncoding(Sniffed, SniffedConfidence);
  if MarkLength > 0 then
    Delete(FPendingBytes, 1, MarkLength);
end;

procedure THtmlParser.DecodeIntoInput(Bytes: PByte; Count: SizeInt; Flush: Boolean);
var
  Index: SizeInt;
begin
  if FAllAsciiSoFar then
    for Index := 1 to Count do
      if Bytes[Index - 1] >= $80 then
      begin
        FAllAsciiSoFar := False;
        Break;
      end;
  FDecoded.Clear;
  FDecoder.Decode(Bytes, Count, FDecoded, Flush);
  FInput.Append(FDecoded.Data, FDecoded.Length);
end;

function THtmlParser.TransportCharsetKnown: Boolean;
var
  Labelled: TTextEncoding;
begin
  Result := (FTransportCharset <> '') and EncodingForLabel(FTransportCharset, Labelled);
end;

procedure THtmlParser.WriteBytes(Bytes: PByte; Count: SizeInt);
var
  Pending: string;
begin
  if FEnded or (Count <= 0) then
    Exit;
  if not FEncodingDecided then
  begin
    SetLength(Pending, Count);
    Move(Bytes^, Pending[1], Count);
    FPendingBytes := FPendingBytes + Pending;
    { A transport charset decides it once a byte order mark could be
      seen; otherwise the prescan wants its 1024 bytes. }
    if (Length(FPendingBytes) < PrescanLength) and
       not ((Length(FPendingBytes) >= 3) and TransportCharsetKnown) then
      Exit;
    DecideEncoding;
    Pending := FPendingBytes;
    FPendingBytes := '';
    DecodeIntoInput(PByte(PChar(Pending)), Length(Pending), False);
  end
  else
    DecodeIntoInput(Bytes, Count, False);
  Pump;
end;

procedure THtmlParser.WriteByteString(const Bytes: string);
begin
  WriteBytes(PByte(PChar(Bytes)), Length(Bytes));
end;

procedure THtmlParser.WriteText(const Text: string);
begin
  if FEnded then
    Exit;
  if not FEncodingDecided then
  begin
    FEncodingDecided := True;
    FConfidence := ConfidenceIrrelevant;
  end;
  FInput.AppendString(Text);
  Pump;
end;

procedure THtmlParser.Finish;
var
  Pending: string;
begin
  if FFinished then
    Exit;
  FFinished := True;
  if not FEncodingDecided then
  begin
    DecideEncoding;
    Pending := FPendingBytes;
    FPendingBytes := '';
    DecodeIntoInput(PByte(PChar(Pending)), Length(Pending), True);
  end
  else if FDecoder <> nil then
    DecodeIntoInput(nil, 0, True);
  FInput.MarkEnded;
  Pump;
end;

procedure THtmlParser.Pump;
begin
  if FPaused or FEnded or FRestartRequested then
    Exit;
  case FTokenizer.Run of
    RunEnded:
      FEnded := True;
  end;
end;

procedure THtmlParser.HandleScriptEnd(Script: TElement);
var
  HadInsertionPoint: Boolean;
  Blocking: Boolean;
begin
  if FScriptHost = nil then
    Exit;
  HadInsertionPoint := FInput.HasInsertionPoint;
  FInput.SetInsertionPointHere;
  Inc(FScriptNestingLevel);
  try
    Blocking := FScriptHost.ScriptEndTagReached(Self, Script);
  finally
    Dec(FScriptNestingLevel);
  end;
  if not HadInsertionPoint then
    FInput.ClearInsertionPoint;
  if Blocking then
  begin
    FPaused := True;
    FTokenizer.RequestStop;
  end;
end;

procedure THtmlParser.Resume;
begin
  if not FPaused then
    Exit;
  FPaused := False;
  Pump;
end;

procedure THtmlParser.DocumentWrite(const Text: string);
begin
  FInput.InsertAtInsertionPoint(Text);
  if FPaused or not FInput.HasInsertionPoint then
    Exit;
  FInput.LimitToInsertionPoint;
  try
    FTokenizer.Run;
  finally
    FInput.RemoveLimit;
  end;
end;

procedure THtmlParser.HandleEncodingDeclared(const Value: string; FromContent: Boolean);
var
  Declared: TTextEncoding;
  Found: Boolean;
begin
  if FConfidence <> ConfidenceTentative then
    Exit;
  if FromContent then
    Found := ExtractEncodingFromContent(Value, Declared)
  else
    Found := EncodingForLabel(Value, Declared);
  if not Found then
    Exit;
  if Declared in [TextEncodingUtf16Be, TextEncodingUtf16Le] then
    Declared := TextEncodingUtf8;
  if Declared = TextEncodingXUserDefined then
    Declared := TextEncodingWindows1252;
  if Declared = FEncoding then
  begin
    FConfidence := ConfidenceCertain;
    Exit;
  end;
  if FAllAsciiSoFar and IsDecodableEncoding(Declared) then
  begin
    { Everything so far reads the same in the new encoding. }
    SetEncoding(Declared, ConfidenceCertain);
    Exit;
  end;
  FRestartRequested := True;
  FRestartEncoding := Declared;
  FTokenizer.RequestStop;
end;

function ParseWithEncoding(const Bytes, TransportCharset: string; Encoding: TTextEncoding; Forced: Boolean;
  out Restart: TTextEncoding): TDocument;
var
  Parser: THtmlParser;
  Bom: TTextEncoding;
  MarkLength: Integer;
  Body: string;
begin
  Result := TDocument.CreateDocument(True);
  Parser := THtmlParser.Create(Result);
  try
    Body := Bytes;
    if Forced then
    begin
      if SniffByteOrderMark(PByte(PChar(Body)), Length(Body), Bom, MarkLength) then
      begin
        Encoding := Bom;
        Delete(Body, 1, MarkLength);
      end;
      Parser.SetEncoding(Encoding, ConfidenceCertain);
    end
    else
      Parser.SetTransportCharset(TransportCharset);
    Parser.WriteByteString(Body);
    Parser.Finish;
    if Parser.RestartRequested then
    begin
      Restart := Parser.RestartEncoding;
      Result.Release;
      Result := nil;
    end;
  finally
    Parser.Free;
  end;
end;

function ParseHtmlDocument(const Bytes: string; const TransportCharset: string): TDocument;
var
  Restart: TTextEncoding;
begin
  Result := ParseWithEncoding(Bytes, TransportCharset, TextEncodingUtf8, False, Restart);
  if Result = nil then
    Result := ParseWithEncoding(Bytes, '', Restart, True, Restart);
end;

function ParseHtmlText(const Text: string; ScriptingEnabled: Boolean): TDocument;
var
  Parser: THtmlParser;
begin
  Result := TDocument.CreateDocument(True);
  Result.ScriptingEnabled := ScriptingEnabled;
  Parser := THtmlParser.Create(Result);
  try
    Parser.WriteText(Text);
    Parser.Finish;
  finally
    Parser.Free;
  end;
end;

function ParseHtmlFragment(Context: TElement; const Text: string): TDocumentFragment;
var
  Scratch: TDocument;
  Parser: THtmlParser;
  Root: TNode;
begin
  Scratch := TDocument.CreateDocument(True);
  try
    Scratch.Mode := Context.NodeDocument.Mode;
    Scratch.ScriptingEnabled := Context.NodeDocument.ScriptingEnabled;
    Parser := THtmlParser.Create(Scratch);
    try
      Parser.TreeBuilder.SetUpFragment(Context);
      Parser.WriteText(Text);
      Parser.Finish;
    finally
      Parser.Free;
    end;
    Result := Context.NodeDocument.CreateDocumentFragment;
    Root := Scratch.DocumentElement;
    while Root.FirstChild <> nil do
      Result.InsertNodeBefore(Root.FirstChild, nil);
  finally
    Scratch.Release;
  end;
end;

end.
