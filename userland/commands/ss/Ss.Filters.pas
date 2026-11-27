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
  ss's filter: what follows the options on its command line, in
  iproute2's words.

    [ state STATE | exclude STATE ]... [ EXPRESSION ]

  STATE is a socket state (established, syn-sent, syn-recv, fin-wait-1,
  fin-wait-2, time-wait, closed, close-wait, last-ack, listening,
  closing) or a group of them (all, connected, synchronized, bucket,
  big). Several "state" add up; "exclude" takes states away.

  EXPRESSION is made of
    sport OP PORT, dport OP PORT    OP: = == eq != ne neq < lt > gt <= le
                                    >= ge (none: =); PORT: ":22", "22",
                                    ":ssh" (a name through the resolver
                                    given), or "*"
    src ADDRESS, dst ADDRESS        10.0.2.15, 10.0.0.0/8, 10.0.2.2:53,
                                    [::1]:22, ::1, "*"
  joined by "and" (also "&&", "&" or nothing), "or" ("||", "|"), "not"
  ("!") and parentheses. The words may be given as separate arguments
  or in one ("( dport = :ssh or sport = :ssh )").

  Plain Pascal over the ABI's types, checked on the host by
  tools/NetstatTest.
}
unit Ss.Filters;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Sys.InternetAddresses;

type
  { The states ss knows, in its order. }
  TSocketState = (StateEstablished, StateSynSent, StateSynReceived, StateFinWait1, StateFinWait2,
    StateTimeWait, StateClosed, StateCloseWait, StateLastAck, StateListen, StateClosing);
  TSocketStates = set of TSocketState;

  { What a filter looks at in a socket. }
  TSocketFacts = record
    State: TSocketState;
    LocalAddress, PeerAddress: TInternetAddress;
    LocalPort, PeerPort: Word;
  end;

  TComparison = (CompareEqual, CompareNotEqual, CompareLess, CompareGreater, CompareLessOrEqual,
    CompareGreaterOrEqual);

  TFilterNodeKind = (NodeAnd, NodeOr, NodeNot, NodeSourcePort, NodeDestinationPort, NodeSource,
    NodeDestination);

  TFilterNode = class
  public
    Kind: TFilterNodeKind;
    Left, Right: TFilterNode;
    Comparison: TComparison;
    { Ports; for addresses the port to match when HasPort. }
    Port: Word;
    AnyPort: Boolean;
    HasPort: Boolean;
    AnyAddress: Boolean;
    Address: TInternetAddress;
    PrefixLength: LongWord;
    destructor Destroy; override;
  end;

  TSocketFilter = record
    { Some "state" was given: States are the ones asked for. }
    HasStates: Boolean;
    States: TSocketStates;
    Excluded: TSocketStates;
    { nil: every socket. }
    Expression: TFilterNode;
  end;

  { A service name's port ("ssh": 22). }
  TPortNameResolver = function(const Name: string; out Port: Word): Boolean;

const
  AllSocketStates = [Low(TSocketState)..High(TSocketState)];
  { What ss shows without -a or -l: no listeners, nothing unconnected,
    no half open or finished connections. }
  DefaultSocketStates = AllSocketStates - [StateListen, StateClosed, StateTimeWait, StateSynReceived];
  ListeningSocketStates = [StateListen, StateClosed];

{ Parses Words (the operands); Resolver may be nil (names then fail).
  On failure ErrorText says what is wrong. }
function ParseSocketFilter(const Words: array of string; Resolver: TPortNameResolver;
  out Filter: TSocketFilter; out ErrorText: string): Boolean;
procedure FreeSocketFilter(var Filter: TSocketFilter);
{ The states to show: the filter's, else Defaults; less the excluded. }
function EffectiveStates(constref Filter: TSocketFilter; Defaults: TSocketStates): TSocketStates;
{ True when the socket passes the expression (states aside). }
function ExpressionMatches(Node: TFilterNode; constref Facts: TSocketFacts): Boolean;
{ "ESTAB", "LISTEN", "UNCONN"... as ss shows them. }
function SocketStateName(State: TSocketState): string;
{ The states a name in a filter means; False for an unknown name. }
function StatesOfName(const Name: string; out States: TSocketStates): Boolean;

implementation

const
  StateNames: array[TSocketState] of string = ('ESTAB', 'SYN-SENT', 'SYN-RECV', 'FIN-WAIT-1', 'FIN-WAIT-2',
    'TIME-WAIT', 'UNCONN', 'CLOSE-WAIT', 'LAST-ACK', 'LISTEN', 'CLOSING');
  StateFilterNames: array[TSocketState] of string = ('established', 'syn-sent', 'syn-recv', 'fin-wait-1',
    'fin-wait-2', 'time-wait', 'closed', 'close-wait', 'last-ack', 'listening', 'closing');

type
  TFilterParser = record
    Tokens: TStringArray;
    Position: Integer;
    Resolver: TPortNameResolver;
    ErrorText: string;
  end;

destructor TFilterNode.Destroy;
begin
  Left.Free;
  Right.Free;
  inherited Destroy;
end;

function SocketStateName(State: TSocketState): string;
begin
  Result := StateNames[State];
end;

function StatesOfName(const Name: string; out States: TSocketStates): Boolean;
var
  State: TSocketState;
begin
  Result := True;
  States := [];
  if SameText(Name, 'all') then
    States := AllSocketStates
  else if SameText(Name, 'connected') then
    States := AllSocketStates - [StateListen, StateClosed]
  else if SameText(Name, 'synchronized') then
    States := AllSocketStates - [StateListen, StateClosed, StateSynSent]
  else if SameText(Name, 'bucket') then
    States := [StateSynReceived, StateTimeWait]
  else if SameText(Name, 'big') then
    States := AllSocketStates - [StateSynReceived, StateTimeWait]
  else if SameText(Name, 'listen') then
    States := [StateListen]
  else
  begin
    for State := Low(TSocketState) to High(TSocketState) do
      if SameText(Name, StateFilterNames[State]) then
      begin
        States := [State];
        Exit;
      end;
    Result := False;
  end;
end;

{ The words split further at blanks, with "(" and ")" words of their own. }
function Tokenize(const Words: array of string): TStringArray;
var
  Tokens: TStringArray;
  Word: string;
  Character: Char;
  Current: string;

  procedure Flush;
  begin
    if Current <> '' then
    begin
      SetLength(Tokens, Length(Tokens) + 1);
      Tokens[High(Tokens)] := Current;
      Current := '';
    end;
  end;

begin
  Tokens := nil;
  Current := '';
  for Word in Words do
  begin
    for Character in Word do
      case Character of
        ' ', #9, #10, #13: Flush;
        '(', ')':
          begin
            Flush;
            Current := Character;
            Flush;
          end;
      else
        Current := Current + Character;
      end;
    Flush;
  end;
  Result := Tokens;
end;

function AtEnd(constref Parser: TFilterParser): Boolean;
begin
  Result := Parser.Position > High(Parser.Tokens);
end;

function Peek(constref Parser: TFilterParser): string;
begin
  if AtEnd(Parser) then
    Result := ''
  else
    Result := Parser.Tokens[Parser.Position];
end;

function Take(var Parser: TFilterParser): string;
begin
  Result := Peek(Parser);
  Inc(Parser.Position);
end;

function Failed(var Parser: TFilterParser; const Text: string): TFilterNode;
begin
  if Parser.ErrorText = '' then
    Parser.ErrorText := Text;
  Result := nil;
end;

function ComparisonOfWord(const Word: string; out Comparison: TComparison): Boolean;
begin
  Result := True;
  if (Word = '=') or (Word = '==') or SameText(Word, 'eq') then
    Comparison := CompareEqual
  else if (Word = '!=') or SameText(Word, 'ne') or SameText(Word, 'neq') then
    Comparison := CompareNotEqual
  else if (Word = '<') or SameText(Word, 'lt') then
    Comparison := CompareLess
  else if (Word = '>') or SameText(Word, 'gt') then
    Comparison := CompareGreater
  else if (Word = '<=') or SameText(Word, 'le') then
    Comparison := CompareLessOrEqual
  else if (Word = '>=') or SameText(Word, 'ge') then
    Comparison := CompareGreaterOrEqual
  else
    Result := False;
end;

{ ":22", "22", ":ssh", "ssh", "*" or ":*". }
function ParsePortText(constref Parser: TFilterParser; const Text: string; out Port: Word;
  out AnyPort: Boolean): Boolean;
var
  Body: string;
  Number: LongInt;
begin
  Port := 0;
  AnyPort := False;
  Body := Text;
  if (Body <> '') and (Body[1] = ':') then
    Delete(Body, 1, 1);
  if Body = '' then
    Exit(False);
  if Body = '*' then
  begin
    AnyPort := True;
    Exit(True);
  end;
  if Body[1] in ['0'..'9'] then
  begin
    Result := TryStrToInt(Body, Number) and (Number >= 0) and (Number <= 65535);
    if Result then
      Port := Number;
    Exit;
  end;
  Result := Assigned(Parser.Resolver) and Parser.Resolver(Body, Port);
end;

function ParsePortCondition(var Parser: TFilterParser; Kind: TFilterNodeKind): TFilterNode;
var
  Comparison: TComparison;
  Text: string;
  Port: Word;
  AnyPort: Boolean;
begin
  Comparison := CompareEqual;
  if ComparisonOfWord(Peek(Parser), Comparison) then
    Take(Parser);
  Text := Take(Parser);
  if Text = '' then
    Exit(Failed(Parser, 'a port is missing'));
  if not ParsePortText(Parser, Text, Port, AnyPort) then
    Exit(Failed(Parser, Format('''%s'' is not a port', [Text])));
  if AnyPort and not (Comparison in [CompareEqual, CompareNotEqual]) then
    Exit(Failed(Parser, '"*" can only be compared for equality'));
  Result := TFilterNode.Create;
  Result.Kind := Kind;
  Result.Comparison := Comparison;
  Result.Port := Port;
  Result.AnyPort := AnyPort;
end;

{ "ADDRESS[/N]" into Node (no port). }
function ParseHostPart(const Text: string; Node: TFilterNode): Boolean;
var
  HasPrefix: Boolean;
begin
  if Text = '*' then
  begin
    Node.AnyAddress := True;
    Exit(True);
  end;
  Result := TextToAddressWithPrefix(Text, Node.Address, Node.PrefixLength, HasPrefix);
end;

{ "10.0.2.2", "10.0.0.0/8", "10.0.2.2:53", "[::1]:22", "::1", "*:22". }
function ParseAddressText(constref Parser: TFilterParser; const Text: string; Node: TFilterNode): Boolean;
var
  Closing, Colon: Integer;
  HostPart, PortPart: string;
begin
  Result := False;
  if Text = '' then
    Exit;
  HostPart := Text;
  PortPart := '';
  if Text[1] = '[' then
  begin
    Closing := Pos(']', Text);
    if Closing = 0 then
      Exit;
    HostPart := Copy(Text, 2, Closing - 2);
    PortPart := Copy(Text, Closing + 1, MaxInt);
    if (PortPart <> '') and (PortPart[1] = '/') then
    begin
      { "[2001:db8::]/32:80" is not taken; "[2001:db8::]/32" is. }
      HostPart := HostPart + PortPart;
      PortPart := '';
    end;
  end
  else if not ParseHostPart(Text, Node) then
  begin
    { Not an address as it is: the last colon starts a port. }
    Colon := LastDelimiter(':', Text);
    if Colon = 0 then
      Exit;
    HostPart := Copy(Text, 1, Colon - 1);
    PortPart := Copy(Text, Colon, MaxInt);
  end
  else
    Exit(True);
  if not ParseHostPart(HostPart, Node) then
    Exit;
  if PortPart <> '' then
  begin
    if PortPart[1] <> ':' then
      Exit;
    if not ParsePortText(Parser, PortPart, Node.Port, Node.AnyPort) then
      Exit;
    Node.HasPort := not Node.AnyPort;
  end;
  Result := True;
end;

function ParseAddressCondition(var Parser: TFilterParser; Kind: TFilterNodeKind): TFilterNode;
var
  Comparison: TComparison;
  Text: string;
  Negated: Boolean;
  Inner: TFilterNode;
begin
  Negated := False;
  if ComparisonOfWord(Peek(Parser), Comparison) then
  begin
    if not (Comparison in [CompareEqual, CompareNotEqual]) then
      Exit(Failed(Parser, 'addresses can only be compared for equality'));
    Negated := Comparison = CompareNotEqual;
    Take(Parser);
  end;
  Text := Take(Parser);
  Inner := TFilterNode.Create;
  Inner.Kind := Kind;
  if not ParseAddressText(Parser, Text, Inner) then
  begin
    Inner.Free;
    Exit(Failed(Parser, Format('''%s'' is not an address', [Text])));
  end;
  if not Negated then
    Exit(Inner);
  Result := TFilterNode.Create;
  Result.Kind := NodeNot;
  Result.Left := Inner;
end;

function ParseOr(var Parser: TFilterParser): TFilterNode; forward;

function ParsePrimary(var Parser: TFilterParser): TFilterNode;
var
  Word: string;
  Inner: TFilterNode;
begin
  Word := Take(Parser);
  if Word = '' then
    Exit(Failed(Parser, 'the expression ends too early'));
  if (Word = '!') or SameText(Word, 'not') then
  begin
    Inner := ParsePrimary(Parser);
    if Inner = nil then
      Exit(nil);
    Result := TFilterNode.Create;
    Result.Kind := NodeNot;
    Result.Left := Inner;
  end
  else if Word = '(' then
  begin
    Result := ParseOr(Parser);
    if Result = nil then
      Exit;
    if Take(Parser) <> ')' then
    begin
      FreeAndNil(Result);
      Exit(Failed(Parser, 'a ")" is missing'));
    end;
  end
  else if SameText(Word, 'sport') then
    Result := ParsePortCondition(Parser, NodeSourcePort)
  else if SameText(Word, 'dport') then
    Result := ParsePortCondition(Parser, NodeDestinationPort)
  else if SameText(Word, 'src') then
    Result := ParseAddressCondition(Parser, NodeSource)
  else if SameText(Word, 'dst') then
    Result := ParseAddressCondition(Parser, NodeDestination)
  else
    Result := Failed(Parser, Format('unexpected ''%s'' in the filter', [Word]));
end;

function IsAndWord(const Word: string): Boolean;
begin
  Result := SameText(Word, 'and') or (Word = '&&') or (Word = '&');
end;

function IsOrWord(const Word: string): Boolean;
begin
  Result := SameText(Word, 'or') or (Word = '||') or (Word = '|');
end;

function Combine(Kind: TFilterNodeKind; Left, Right: TFilterNode): TFilterNode;
begin
  Result := TFilterNode.Create;
  Result.Kind := Kind;
  Result.Left := Left;
  Result.Right := Right;
end;

function ParseAnd(var Parser: TFilterParser): TFilterNode;
var
  Right: TFilterNode;
begin
  Result := ParsePrimary(Parser);
  while (Result <> nil) and not AtEnd(Parser) and (Peek(Parser) <> ')') and not IsOrWord(Peek(Parser)) do
  begin
    if IsAndWord(Peek(Parser)) then
      Take(Parser);
    Right := ParsePrimary(Parser);
    if Right = nil then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    Result := Combine(NodeAnd, Result, Right);
  end;
end;

function ParseOr(var Parser: TFilterParser): TFilterNode;
var
  Right: TFilterNode;
begin
  Result := ParseAnd(Parser);
  while (Result <> nil) and IsOrWord(Peek(Parser)) do
  begin
    Take(Parser);
    Right := ParseAnd(Parser);
    if Right = nil then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    Result := Combine(NodeOr, Result, Right);
  end;
end;

{ "state X" and "exclude X" at the front. }
function ParseStates(var Parser: TFilterParser; var Filter: TSocketFilter): Boolean;
var
  Word, Name: string;
  States: TSocketStates;
begin
  Result := True;
  while not AtEnd(Parser) do
  begin
    Word := Peek(Parser);
    if not SameText(Word, 'state') and not SameText(Word, 'exclude') and not SameText(Word, 'excl') then
      Exit;
    Take(Parser);
    Name := Take(Parser);
    if not StatesOfName(Name, States) then
    begin
      Parser.ErrorText := Format('unknown state ''%s''', [Name]);
      Exit(False);
    end;
    if SameText(Word, 'state') then
    begin
      Filter.HasStates := True;
      Filter.States := Filter.States + States;
    end
    else
      Filter.Excluded := Filter.Excluded + States;
  end;
end;

function ParseSocketFilter(const Words: array of string; Resolver: TPortNameResolver;
  out Filter: TSocketFilter; out ErrorText: string): Boolean;
var
  Parser: TFilterParser;
begin
  Filter := Default(TSocketFilter);
  Parser := Default(TFilterParser);
  Parser.Tokens := Tokenize(Words);
  Parser.Resolver := Resolver;
  Result := False;
  if not ParseStates(Parser, Filter) then
  begin
    ErrorText := Parser.ErrorText;
    Exit;
  end;
  if not AtEnd(Parser) then
  begin
    Filter.Expression := ParseOr(Parser);
    if (Filter.Expression <> nil) and not AtEnd(Parser) then
    begin
      Parser.ErrorText := Format('unexpected ''%s'' in the filter', [Peek(Parser)]);
      FreeAndNil(Filter.Expression);
    end;
    if Filter.Expression = nil then
    begin
      ErrorText := Parser.ErrorText;
      Exit;
    end;
  end;
  ErrorText := '';
  Result := True;
end;

procedure FreeSocketFilter(var Filter: TSocketFilter);
begin
  FreeAndNil(Filter.Expression);
end;

function EffectiveStates(constref Filter: TSocketFilter; Defaults: TSocketStates): TSocketStates;
begin
  if Filter.HasStates then
    Result := Filter.States
  else
    Result := Defaults;
  Result := Result - Filter.Excluded;
end;

function PortMatches(Node: TFilterNode; Port: Word): Boolean;
begin
  if Node.AnyPort then
    Exit(Node.Comparison = CompareEqual);
  case Node.Comparison of
    CompareEqual: Result := Port = Node.Port;
    CompareNotEqual: Result := Port <> Node.Port;
    CompareLess: Result := Port < Node.Port;
    CompareGreater: Result := Port > Node.Port;
    CompareLessOrEqual: Result := Port <= Node.Port;
  else
    Result := Port >= Node.Port;
  end;
end;

function AddressMatches(Node: TFilterNode; constref Address: TInternetAddress; Port: Word): Boolean;
begin
  if Node.HasPort and (Port <> Node.Port) then
    Exit(False);
  if Node.AnyAddress then
    Exit(True);
  Result := (Address.Family = Node.Address.Family) and
    AddressesSharePrefix(Address, Node.Address, Node.PrefixLength);
end;

function ExpressionMatches(Node: TFilterNode; constref Facts: TSocketFacts): Boolean;
begin
  if Node = nil then
    Exit(True);
  case Node.Kind of
    NodeAnd: Result := ExpressionMatches(Node.Left, Facts) and ExpressionMatches(Node.Right, Facts);
    NodeOr: Result := ExpressionMatches(Node.Left, Facts) or ExpressionMatches(Node.Right, Facts);
    NodeNot: Result := not ExpressionMatches(Node.Left, Facts);
    NodeSourcePort: Result := PortMatches(Node, Facts.LocalPort);
    NodeDestinationPort: Result := PortMatches(Node, Facts.PeerPort);
    NodeSource: Result := AddressMatches(Node, Facts.LocalAddress, Facts.LocalPort);
  else
    Result := AddressMatches(Node, Facts.PeerAddress, Facts.PeerPort);
  end;
end;

end.
