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
  The HTML tokenizer (HTML Standard 13.2.5): every state of the state
  machine, character references with the full named reference table,
  and the parse errors by their standard codes.

  It reads the input stream byte by byte (UTF-8; all syntax is ASCII),
  copies plain runs of text in one go, and stops wherever the input runs
  out: the state, the token being built and the temporary buffer are
  fields, so the next piece of input carries on where it stopped. A
  lookahead the standard does in one step ("DOCTYPE", a named reference)
  waits until enough input is there. The tree builder gets each token as
  it is emitted, can switch the state (RCDATA, RAWTEXT, script data,
  PLAINTEXT) and can ask the tokenizer to stop after a token (a script
  end tag: the parser pauses there).

  The states are spread over include files: Web.Html.TokenizerText.inc
  (data, RCDATA, RAWTEXT, script data, PLAINTEXT), ...Tags.inc,
  ...Markup.inc (comments, CDATA), ...Doctype.inc, ...References.inc.
}
unit Web.Html.Tokenizer;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms,
  Web.TextBuffers,
  Web.Html.Tokens,
  Web.Html.InputStream;

type
  TTokenizerState = (
    TsData, TsRcdata, TsRawText, TsScriptData, TsPlainText, TsTagOpen, TsEndTagOpen, TsTagName,
    TsRcdataLessThanSign, TsRcdataEndTagOpen, TsRcdataEndTagName,
    TsRawTextLessThanSign, TsRawTextEndTagOpen, TsRawTextEndTagName,
    TsScriptDataLessThanSign, TsScriptDataEndTagOpen, TsScriptDataEndTagName,
    TsScriptDataEscapeStart, TsScriptDataEscapeStartDash, TsScriptDataEscaped, TsScriptDataEscapedDash,
    TsScriptDataEscapedDashDash, TsScriptDataEscapedLessThanSign, TsScriptDataEscapedEndTagOpen,
    TsScriptDataEscapedEndTagName, TsScriptDataDoubleEscapeStart, TsScriptDataDoubleEscaped,
    TsScriptDataDoubleEscapedDash, TsScriptDataDoubleEscapedDashDash, TsScriptDataDoubleEscapedLessThanSign,
    TsScriptDataDoubleEscapeEnd,
    TsBeforeAttributeName, TsAttributeName, TsAfterAttributeName, TsBeforeAttributeValue,
    TsAttributeValueDoubleQuoted, TsAttributeValueSingleQuoted, TsAttributeValueUnquoted,
    TsAfterAttributeValueQuoted, TsSelfClosingStartTag,
    TsBogusComment, TsMarkupDeclarationOpen, TsCommentStart, TsCommentStartDash, TsComment,
    TsCommentLessThanSign, TsCommentLessThanSignBang, TsCommentLessThanSignBangDash,
    TsCommentLessThanSignBangDashDash, TsCommentEndDash, TsCommentEnd, TsCommentEndBang,
    TsDoctype, TsBeforeDoctypeName, TsDoctypeName, TsAfterDoctypeName, TsAfterDoctypePublicKeyword,
    TsBeforeDoctypePublicIdentifier, TsDoctypePublicIdentifierDoubleQuoted,
    TsDoctypePublicIdentifierSingleQuoted, TsAfterDoctypePublicIdentifier,
    TsBetweenDoctypePublicAndSystemIdentifiers, TsAfterDoctypeSystemKeyword,
    TsBeforeDoctypeSystemIdentifier, TsDoctypeSystemIdentifierDoubleQuoted,
    TsDoctypeSystemIdentifierSingleQuoted, TsAfterDoctypeSystemIdentifier, TsBogusDoctype,
    TsCdataSection, TsCdataSectionBracket, TsCdataSectionEnd,
    TsCharacterReference, TsNamedCharacterReference, TsAmbiguousAmpersand, TsNumericCharacterReference,
    TsHexadecimalCharacterReferenceStart, TsDecimalCharacterReferenceStart,
    TsHexadecimalCharacterReference, TsDecimalCharacterReference, TsNumericCharacterReferenceEnd,
    TsEnded);

  { What the tokenizer feeds: the tree builder. }
  TTokenSink = class
  public
    procedure ProcessToken(var Token: TToken); virtual; abstract;
    { Whether there is an adjusted current node and it is not in the HTML
      namespace (CDATA sections are allowed only then). }
    function AdjustedCurrentNodeIsForeign: Boolean; virtual; abstract;
  end;

  TParseErrorEvent = procedure(const Code: string) of object;

  TTokenizerRunResult = (
    { The input (up to the limit) is used up. }
    RunNeedsInput,
    { The tree builder asked to stop after a token. }
    RunStopped,
    { The end of the file was emitted. }
    RunEnded);

  THtmlTokenizer = class
  private
    FInput: THtmlInputStream;
    FSink: TTokenSink;
    FState: TTokenizerState;
    FReturnState: TTokenizerState;
    FToken: TToken;
    FCharacters: TTextBuffer;
    FTagName: TTextBuffer;
    FIsEndTag: Boolean;
    FAttributeName: TTextBuffer;
    FAttributeValue: TTextBuffer;
    FHaveAttribute: Boolean;
    FAttributeNameAtom: TAtom;
    FAttributeDuplicate: Boolean;
    FTemporaryBuffer: TTextBuffer;
    FCommentData: TTextBuffer;
    FDoctypeName: TTextBuffer;
    FPublicId: TTextBuffer;
    FSystemId: TTextBuffer;
    FLastStartTagName: TAtom;
    FCharacterReferenceCode: LongWord;
    FErrorCount: SizeInt;
    FOnParseError: TParseErrorEvent;
    FStopRequested: Boolean;
    procedure ParseError(const Code: string);
    { Emitting }
    procedure EmitByte(Value: Byte); inline;
    procedure EmitText(Text: PChar; Count: SizeInt); inline;
    procedure EmitString(const Text: string);
    procedure EmitReplacementCharacter;
    procedure EmitNull;
    procedure FlushCharacters;
    procedure EmitToken;
    procedure EmitTag;
    procedure EmitComment;
    procedure EmitDoctype;
    procedure EmitEndOfFile;
    { Tags }
    procedure StartTag(EndTag: Boolean);
    procedure StartAttribute;
    procedure LeaveAttributeName;
    procedure CommitAttribute;
    function IsAppropriateEndTag: Boolean;
    procedure StartDoctype;
    function IsInAttributeValue: Boolean; inline;
    procedure FlushCharacterReference;
    procedure AppendToAttributeOrEmit(Value: Byte);
    { One step of each state: False to wait for more input. }
    function StepData: Boolean;
    function StepRcdata: Boolean;
    function StepRawText: Boolean;
    function StepScriptData: Boolean;
    function StepPlainText: Boolean;
    function StepTagOpen: Boolean;
    function StepEndTagOpen: Boolean;
    function StepTagName: Boolean;
    function StepTextLessThanSign(EndTagOpenState, TextState: TTokenizerState): Boolean;
    function StepTextEndTagOpen(EndTagNameState, TextState: TTokenizerState): Boolean;
    function StepTextEndTagName(TextState: TTokenizerState): Boolean;
    function StepScriptDataLessThanSign: Boolean;
    function StepScriptDataEscapeStart: Boolean;
    function StepScriptDataEscapeStartDash: Boolean;
    function StepScriptDataEscaped: Boolean;
    function StepScriptDataEscapedDash: Boolean;
    function StepScriptDataEscapedDashDash: Boolean;
    function StepScriptDataEscapedLessThanSign: Boolean;
    function StepScriptDataDoubleEscapeStart: Boolean;
    function StepScriptDataDoubleEscaped: Boolean;
    function StepScriptDataDoubleEscapedDash: Boolean;
    function StepScriptDataDoubleEscapedDashDash: Boolean;
    function StepScriptDataDoubleEscapedLessThanSign: Boolean;
    function StepScriptDataDoubleEscapeEnd: Boolean;
    function StepBeforeAttributeName: Boolean;
    function StepAttributeName: Boolean;
    function StepAfterAttributeName: Boolean;
    function StepBeforeAttributeValue: Boolean;
    function StepAttributeValueQuoted(Quote: Byte): Boolean;
    function StepAttributeValueUnquoted: Boolean;
    function StepAfterAttributeValueQuoted: Boolean;
    function StepSelfClosingStartTag: Boolean;
    function StepBogusComment: Boolean;
    function StepMarkupDeclarationOpen: Boolean;
    function StepCommentStart: Boolean;
    function StepCommentStartDash: Boolean;
    function StepComment: Boolean;
    function StepCommentLessThanSign: Boolean;
    function StepCommentLessThanSignBang: Boolean;
    function StepCommentLessThanSignBangDash: Boolean;
    function StepCommentLessThanSignBangDashDash: Boolean;
    function StepCommentEndDash: Boolean;
    function StepCommentEnd: Boolean;
    function StepCommentEndBang: Boolean;
    function StepDoctype: Boolean;
    function StepBeforeDoctypeName: Boolean;
    function StepDoctypeName: Boolean;
    function StepAfterDoctypeName: Boolean;
    function StepAfterDoctypeKeyword(IsPublic: Boolean): Boolean;
    function StepBeforeDoctypeIdentifier(IsPublic: Boolean): Boolean;
    function StepDoctypeIdentifierQuoted(IsPublic: Boolean; Quote: Byte): Boolean;
    function StepAfterDoctypePublicIdentifier: Boolean;
    function StepBetweenDoctypePublicAndSystemIdentifiers: Boolean;
    function StepAfterDoctypeSystemIdentifier: Boolean;
    function StepBogusDoctype: Boolean;
    function StepCdataSection: Boolean;
    function StepCdataSectionBracket: Boolean;
    function StepCdataSectionEnd: Boolean;
    function StepCharacterReference: Boolean;
    function StepNamedCharacterReference: Boolean;
    function StepAmbiguousAmpersand: Boolean;
    function StepNumericCharacterReference: Boolean;
    function StepNumericReferenceStart(Hexadecimal: Boolean): Boolean;
    function StepHexadecimalCharacterReference: Boolean;
    function StepDecimalCharacterReference: Boolean;
    function StepNumericCharacterReferenceEnd: Boolean;
    function Step: Boolean;
  public
    constructor Create(Input: THtmlInputStream; Sink: TTokenSink);
    destructor Destroy; override;
    { Tokenizes until the input runs out, a stop is requested or the end
      of the file is emitted. }
    function Run: TTokenizerRunResult;
    { Asks Run to return after the token being processed. }
    procedure RequestStop;
    { The tree builder's state switches. }
    procedure SwitchTo(NewState: TTokenizerState);
    { The last start tag's name (for fragments: the context element's). }
    property LastStartTagName: TAtom read FLastStartTagName write FLastStartTagName;
    property State: TTokenizerState read FState;
    property ErrorCount: SizeInt read FErrorCount;
    property OnParseError: TParseErrorEvent read FOnParseError write FOnParseError;
  end;

implementation

uses
  Web.Html.NamedReferences;

var
  DataStops, RcdataStops, RawTextStops, PlainTextStops, AttributeDoubleStops, AttributeSingleStops,
  CommentStops: TStopTable;

const
  ReplacementCharacterUtf8 = #$EF#$BF#$BD;

type
  TReadResult = (ReadByteAvailable, ReadEndOfFile, ReadSuspend);

constructor THtmlTokenizer.Create(Input: THtmlInputStream; Sink: TTokenSink);
begin
  inherited Create;
  FInput := Input;
  FSink := Sink;
  FState := TsData;
  FCharacters := TTextBuffer.Create;
  FTagName := TTextBuffer.Create;
  FAttributeName := TTextBuffer.Create;
  FAttributeValue := TTextBuffer.Create;
  FTemporaryBuffer := TTextBuffer.Create;
  FCommentData := TTextBuffer.Create;
  FDoctypeName := TTextBuffer.Create;
  FPublicId := TTextBuffer.Create;
  FSystemId := TTextBuffer.Create;
end;

destructor THtmlTokenizer.Destroy;
begin
  FCharacters.Free;
  FTagName.Free;
  FAttributeName.Free;
  FAttributeValue.Free;
  FTemporaryBuffer.Free;
  FCommentData.Free;
  FDoctypeName.Free;
  FPublicId.Free;
  FSystemId.Free;
  inherited Destroy;
end;

procedure THtmlTokenizer.ParseError(const Code: string);
begin
  Inc(FErrorCount);
  if Assigned(FOnParseError) then
    FOnParseError(Code);
end;

procedure THtmlTokenizer.RequestStop;
begin
  FStopRequested := True;
end;

procedure THtmlTokenizer.SwitchTo(NewState: TTokenizerState);
begin
  FState := NewState;
end;

function IsAsciiAlpha(Value: Byte): Boolean; inline;
begin
  Result := Value in [Ord('a')..Ord('z'), Ord('A')..Ord('Z')];
end;

function IsAsciiUpperAlpha(Value: Byte): Boolean; inline;
begin
  Result := Value in [Ord('A')..Ord('Z')];
end;

function IsAsciiAlphanumeric(Value: Byte): Boolean; inline;
begin
  Result := Value in [Ord('a')..Ord('z'), Ord('A')..Ord('Z'), Ord('0')..Ord('9')];
end;

function IsTokenizerWhitespace(Value: Byte): Boolean; inline;
begin
  Result := Value in [9, 10, 12, 32];
end;

function LowerByte(Value: Byte): Char; inline;
begin
  if IsAsciiUpperAlpha(Value) then
    Result := Chr(Value + 32)
  else
    Result := Chr(Value);
end;

{ Emitting }

procedure THtmlTokenizer.EmitByte(Value: Byte);
begin
  FCharacters.AppendChar(Chr(Value));
end;

procedure THtmlTokenizer.EmitText(Text: PChar; Count: SizeInt);
begin
  FCharacters.Append(Text, Count);
end;

procedure THtmlTokenizer.EmitString(const Text: string);
begin
  FCharacters.AppendString(Text);
end;

procedure THtmlTokenizer.EmitReplacementCharacter;
begin
  FCharacters.AppendString(ReplacementCharacterUtf8);
end;

procedure THtmlTokenizer.EmitNull;
begin
  FlushCharacters;
  FCharacters.AppendChar(#0);
  FlushCharacters;
end;

procedure THtmlTokenizer.EmitToken;
begin
  FSink.ProcessToken(FToken);
end;

procedure THtmlTokenizer.FlushCharacters;
begin
  if FCharacters.Length = 0 then
    Exit;
  FToken.Kind := TokenCharacters;
  FToken.Data := FCharacters.TakeText;
  EmitToken;
  FToken.Data := '';
end;

procedure THtmlTokenizer.StartTag(EndTag: Boolean);
begin
  FIsEndTag := EndTag;
  FTagName.Clear;
  FToken.AttributeCount := 0;
  FToken.SelfClosing := False;
  FHaveAttribute := False;
end;

procedure THtmlTokenizer.StartAttribute;
begin
  CommitAttribute;
  FHaveAttribute := True;
  FAttributeName.Clear;
  FAttributeValue.Clear;
  FAttributeNameAtom := AtomNone;
  FAttributeDuplicate := False;
end;

procedure THtmlTokenizer.LeaveAttributeName;
var
  Index: Integer;
begin
  if not FHaveAttribute or (FAttributeNameAtom <> AtomNone) then
    Exit;
  FAttributeNameAtom := AtomizeText(FAttributeName.Data, FAttributeName.Length);
  for Index := 1 to FToken.AttributeCount do
    if FToken.Attributes[Index - 1].Name = FAttributeNameAtom then
    begin
      ParseError('duplicate-attribute');
      FAttributeDuplicate := True;
      Break;
    end;
end;

procedure THtmlTokenizer.CommitAttribute;
var
  Count: Integer;
begin
  if not FHaveAttribute then
    Exit;
  LeaveAttributeName;
  FHaveAttribute := False;
  if FAttributeDuplicate then
    Exit;
  Count := FToken.AttributeCount;
  if Count >= Length(FToken.Attributes) then
    SetLength(FToken.Attributes, Count * 2 + 4);
  FToken.Attributes[Count].Name := FAttributeNameAtom;
  FToken.Attributes[Count].LocalName := FAttributeNameAtom;
  FToken.Attributes[Count].NamespaceId := 0;
  FToken.Attributes[Count].Value := FAttributeValue.Text;
  FToken.AttributeCount := Count + 1;
end;

procedure THtmlTokenizer.EmitTag;
begin
  CommitAttribute;
  FlushCharacters;
  FToken.TagName := AtomizeText(FTagName.Data, FTagName.Length);
  FToken.SelfClosingAcknowledged := False;
  if FIsEndTag then
  begin
    FToken.Kind := TokenEndTag;
    if FToken.AttributeCount > 0 then
      ParseError('end-tag-with-attributes');
    if FToken.SelfClosing then
      ParseError('end-tag-with-trailing-solidus');
    FToken.AttributeCount := 0;
  end
  else
  begin
    FToken.Kind := TokenStartTag;
    FLastStartTagName := FToken.TagName;
  end;
  EmitToken;
  if (FToken.Kind = TokenStartTag) and FToken.SelfClosing and not FToken.SelfClosingAcknowledged then
    ParseError('non-void-html-element-start-tag-with-trailing-solidus');
end;

procedure THtmlTokenizer.EmitComment;
begin
  FlushCharacters;
  FToken.Kind := TokenComment;
  FToken.Data := FCommentData.Text;
  EmitToken;
  FToken.Data := '';
end;

procedure THtmlTokenizer.StartDoctype;
begin
  FDoctypeName.Clear;
  FPublicId.Clear;
  FSystemId.Clear;
  FToken.HasDoctypeName := False;
  FToken.HasPublicId := False;
  FToken.HasSystemId := False;
  FToken.ForceQuirks := False;
end;

procedure THtmlTokenizer.EmitDoctype;
begin
  FlushCharacters;
  FToken.Kind := TokenDoctype;
  FToken.DoctypeName := FDoctypeName.Text;
  FToken.PublicId := FPublicId.Text;
  FToken.SystemId := FSystemId.Text;
  EmitToken;
end;

procedure THtmlTokenizer.EmitEndOfFile;
begin
  FlushCharacters;
  FToken.Kind := TokenEndOfFile;
  EmitToken;
  FState := TsEnded;
end;

function THtmlTokenizer.IsAppropriateEndTag: Boolean;
begin
  Result := (FLastStartTagName <> AtomNone) and FTagName.Equals(NameOfAtom(FLastStartTagName));
end;

function THtmlTokenizer.IsInAttributeValue: Boolean;
begin
  Result := FReturnState in [TsAttributeValueDoubleQuoted, TsAttributeValueSingleQuoted, TsAttributeValueUnquoted];
end;

procedure THtmlTokenizer.FlushCharacterReference;
begin
  if IsInAttributeValue then
    FAttributeValue.Append(FTemporaryBuffer.Data, FTemporaryBuffer.Length)
  else
    EmitText(FTemporaryBuffer.Data, FTemporaryBuffer.Length);
end;

procedure THtmlTokenizer.AppendToAttributeOrEmit(Value: Byte);
begin
  if IsInAttributeValue then
    FAttributeValue.AppendChar(Chr(Value))
  else
    EmitByte(Value);
end;

{ Reads the next input byte: ReadSuspend when it has not arrived yet,
  ReadEndOfFile at the end of the stream. }
function ReadNext(Input: THtmlInputStream; out Value: Byte): TReadResult; inline;
begin
  Value := 0;
  if Input.HasByte then
  begin
    Value := Input.NextByte;
    Exit(ReadByteAvailable);
  end;
  if Input.AtEnd then
    Result := ReadEndOfFile
  else
    Result := ReadSuspend;
end;

{$I Web.Html.TokenizerText.inc}
{$I Web.Html.TokenizerTags.inc}
{$I Web.Html.TokenizerMarkup.inc}
{$I Web.Html.TokenizerDoctype.inc}
{$I Web.Html.TokenizerReferences.inc}

function THtmlTokenizer.Step: Boolean;
begin
  case FState of
    TsData: Result := StepData;
    TsRcdata: Result := StepRcdata;
    TsRawText: Result := StepRawText;
    TsScriptData: Result := StepScriptData;
    TsPlainText: Result := StepPlainText;
    TsTagOpen: Result := StepTagOpen;
    TsEndTagOpen: Result := StepEndTagOpen;
    TsTagName: Result := StepTagName;
    TsRcdataLessThanSign: Result := StepTextLessThanSign(TsRcdataEndTagOpen, TsRcdata);
    TsRcdataEndTagOpen: Result := StepTextEndTagOpen(TsRcdataEndTagName, TsRcdata);
    TsRcdataEndTagName: Result := StepTextEndTagName(TsRcdata);
    TsRawTextLessThanSign: Result := StepTextLessThanSign(TsRawTextEndTagOpen, TsRawText);
    TsRawTextEndTagOpen: Result := StepTextEndTagOpen(TsRawTextEndTagName, TsRawText);
    TsRawTextEndTagName: Result := StepTextEndTagName(TsRawText);
    TsScriptDataLessThanSign: Result := StepScriptDataLessThanSign;
    TsScriptDataEndTagOpen: Result := StepTextEndTagOpen(TsScriptDataEndTagName, TsScriptData);
    TsScriptDataEndTagName: Result := StepTextEndTagName(TsScriptData);
    TsScriptDataEscapeStart: Result := StepScriptDataEscapeStart;
    TsScriptDataEscapeStartDash: Result := StepScriptDataEscapeStartDash;
    TsScriptDataEscaped: Result := StepScriptDataEscaped;
    TsScriptDataEscapedDash: Result := StepScriptDataEscapedDash;
    TsScriptDataEscapedDashDash: Result := StepScriptDataEscapedDashDash;
    TsScriptDataEscapedLessThanSign: Result := StepScriptDataEscapedLessThanSign;
    TsScriptDataEscapedEndTagOpen: Result := StepTextEndTagOpen(TsScriptDataEscapedEndTagName, TsScriptDataEscaped);
    TsScriptDataEscapedEndTagName: Result := StepTextEndTagName(TsScriptDataEscaped);
    TsScriptDataDoubleEscapeStart: Result := StepScriptDataDoubleEscapeStart;
    TsScriptDataDoubleEscaped: Result := StepScriptDataDoubleEscaped;
    TsScriptDataDoubleEscapedDash: Result := StepScriptDataDoubleEscapedDash;
    TsScriptDataDoubleEscapedDashDash: Result := StepScriptDataDoubleEscapedDashDash;
    TsScriptDataDoubleEscapedLessThanSign: Result := StepScriptDataDoubleEscapedLessThanSign;
    TsScriptDataDoubleEscapeEnd: Result := StepScriptDataDoubleEscapeEnd;
    TsBeforeAttributeName: Result := StepBeforeAttributeName;
    TsAttributeName: Result := StepAttributeName;
    TsAfterAttributeName: Result := StepAfterAttributeName;
    TsBeforeAttributeValue: Result := StepBeforeAttributeValue;
    TsAttributeValueDoubleQuoted: Result := StepAttributeValueQuoted(Ord('"'));
    TsAttributeValueSingleQuoted: Result := StepAttributeValueQuoted(Ord(''''));
    TsAttributeValueUnquoted: Result := StepAttributeValueUnquoted;
    TsAfterAttributeValueQuoted: Result := StepAfterAttributeValueQuoted;
    TsSelfClosingStartTag: Result := StepSelfClosingStartTag;
    TsBogusComment: Result := StepBogusComment;
    TsMarkupDeclarationOpen: Result := StepMarkupDeclarationOpen;
    TsCommentStart: Result := StepCommentStart;
    TsCommentStartDash: Result := StepCommentStartDash;
    TsComment: Result := StepComment;
    TsCommentLessThanSign: Result := StepCommentLessThanSign;
    TsCommentLessThanSignBang: Result := StepCommentLessThanSignBang;
    TsCommentLessThanSignBangDash: Result := StepCommentLessThanSignBangDash;
    TsCommentLessThanSignBangDashDash: Result := StepCommentLessThanSignBangDashDash;
    TsCommentEndDash: Result := StepCommentEndDash;
    TsCommentEnd: Result := StepCommentEnd;
    TsCommentEndBang: Result := StepCommentEndBang;
    TsDoctype: Result := StepDoctype;
    TsBeforeDoctypeName: Result := StepBeforeDoctypeName;
    TsDoctypeName: Result := StepDoctypeName;
    TsAfterDoctypeName: Result := StepAfterDoctypeName;
    TsAfterDoctypePublicKeyword: Result := StepAfterDoctypeKeyword(True);
    TsBeforeDoctypePublicIdentifier: Result := StepBeforeDoctypeIdentifier(True);
    TsDoctypePublicIdentifierDoubleQuoted: Result := StepDoctypeIdentifierQuoted(True, Ord('"'));
    TsDoctypePublicIdentifierSingleQuoted: Result := StepDoctypeIdentifierQuoted(True, Ord(''''));
    TsAfterDoctypePublicIdentifier: Result := StepAfterDoctypePublicIdentifier;
    TsBetweenDoctypePublicAndSystemIdentifiers: Result := StepBetweenDoctypePublicAndSystemIdentifiers;
    TsAfterDoctypeSystemKeyword: Result := StepAfterDoctypeKeyword(False);
    TsBeforeDoctypeSystemIdentifier: Result := StepBeforeDoctypeIdentifier(False);
    TsDoctypeSystemIdentifierDoubleQuoted: Result := StepDoctypeIdentifierQuoted(False, Ord('"'));
    TsDoctypeSystemIdentifierSingleQuoted: Result := StepDoctypeIdentifierQuoted(False, Ord(''''));
    TsAfterDoctypeSystemIdentifier: Result := StepAfterDoctypeSystemIdentifier;
    TsBogusDoctype: Result := StepBogusDoctype;
    TsCdataSection: Result := StepCdataSection;
    TsCdataSectionBracket: Result := StepCdataSectionBracket;
    TsCdataSectionEnd: Result := StepCdataSectionEnd;
    TsCharacterReference: Result := StepCharacterReference;
    TsNamedCharacterReference: Result := StepNamedCharacterReference;
    TsAmbiguousAmpersand: Result := StepAmbiguousAmpersand;
    TsNumericCharacterReference: Result := StepNumericCharacterReference;
    TsHexadecimalCharacterReferenceStart: Result := StepNumericReferenceStart(True);
    TsDecimalCharacterReferenceStart: Result := StepNumericReferenceStart(False);
    TsHexadecimalCharacterReference: Result := StepHexadecimalCharacterReference;
    TsDecimalCharacterReference: Result := StepDecimalCharacterReference;
    TsNumericCharacterReferenceEnd: Result := StepNumericCharacterReferenceEnd;
  else
    Result := False;
  end;
end;

function THtmlTokenizer.Run: TTokenizerRunResult;
begin
  FStopRequested := False;
  while True do
  begin
    if FState = TsEnded then
      Exit(RunEnded);
    if not Step then
    begin
      { Out of input: what is pending goes now, since the tree builder
        merges adjacent text anyway. }
      FlushCharacters;
      if FStopRequested then
        Exit(RunStopped);
      Exit(RunNeedsInput);
    end;
    if FStopRequested then
    begin
      FlushCharacters;
      Exit(RunStopped);
    end;
  end;
end;

procedure MakeStopTable(out Table: TStopTable; const Stops: array of Byte);
var
  Index: Integer;
begin
  FillChar(Table, SizeOf(Table), 0);
  for Index := 0 to High(Stops) do
    Table[Stops[Index]] := True;
end;

initialization
  MakeStopTable(DataStops, [Ord('<'), Ord('&'), 0]);
  MakeStopTable(RcdataStops, [Ord('<'), Ord('&'), 0]);
  MakeStopTable(RawTextStops, [Ord('<'), 0]);
  MakeStopTable(PlainTextStops, [0]);
  MakeStopTable(AttributeDoubleStops, [Ord('"'), Ord('&'), 0]);
  MakeStopTable(AttributeSingleStops, [Ord(''''), Ord('&'), 0]);
  MakeStopTable(CommentStops, [Ord('<'), Ord('-'), 0]);
end.
