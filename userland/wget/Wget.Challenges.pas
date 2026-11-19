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
  The challenges of a WWW-Authenticate field (RFC 9110 section 11.6.1):

    Digest realm="api", qop="auth, auth-int", nonce="abc", Basic realm="x"

  A field may hold several challenges, and a response several fields;
  each challenge is a scheme and its parameters (name=token or
  name="quoted string", with \-escapes), or a token68 (kept as the
  parameter with an empty name). Parameter names compare without case.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.Challenges;

{$mode objfpc}
{$H+}

interface

type
  TChallengeParameter = record
    Name, Value: string;
  end;

  TChallenge = record
    Scheme: string;
    Parameters: array of TChallengeParameter;
  end;

  TChallengeArray = array of TChallenge;

{ Adds the challenges of one field value to Challenges. }
procedure ParseChallenges(const FieldValue: string; var Challenges: TChallengeArray);
{ A parameter's value ('' when missing). }
function ChallengeParameter(constref Challenge: TChallenge; const Name: string): string;
function ChallengeHasParameter(constref Challenge: TChallenge; const Name: string): Boolean;

implementation

uses
  SysUtils;

const
  TokenCharacters = ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~', '0'..'9',
    'a'..'z', 'A'..'Z'];
  Token68Characters = ['0'..'9', 'a'..'z', 'A'..'Z', '-', '.', '_', '~', '+', '/', '='];
  Blanks = [' ', #9];

type
  TChallengeReader = record
    Text: string;
    Position: Integer;
  end;

procedure SkipBlanks(var Reader: TChallengeReader);
begin
  while (Reader.Position <= Length(Reader.Text)) and (Reader.Text[Reader.Position] in Blanks) do
    Inc(Reader.Position);
end;

procedure SkipBlanksAndCommas(var Reader: TChallengeReader);
begin
  while (Reader.Position <= Length(Reader.Text)) and (Reader.Text[Reader.Position] in Blanks + [',']) do
    Inc(Reader.Position);
end;

function CurrentCharacter(constref Reader: TChallengeReader): Char;
begin
  if Reader.Position <= Length(Reader.Text) then
    Result := Reader.Text[Reader.Position]
  else
    Result := #0;
end;

function ReadToken(var Reader: TChallengeReader): string;
var
  Start: Integer;
begin
  Start := Reader.Position;
  while (Reader.Position <= Length(Reader.Text)) and (Reader.Text[Reader.Position] in TokenCharacters) do
    Inc(Reader.Position);
  Result := Copy(Reader.Text, Start, Reader.Position - Start);
end;

function ReadQuoted(var Reader: TChallengeReader): string;
begin
  Result := '';
  { At the opening quote. }
  Inc(Reader.Position);
  while Reader.Position <= Length(Reader.Text) do
  begin
    case Reader.Text[Reader.Position] of
      '"':
        begin
          Inc(Reader.Position);
          Exit;
        end;
      '\':
        begin
          Inc(Reader.Position);
          if Reader.Position <= Length(Reader.Text) then
            Result := Result + Reader.Text[Reader.Position];
        end;
    else
      Result := Result + Reader.Text[Reader.Position];
    end;
    Inc(Reader.Position);
  end;
end;

procedure AddParameter(var Challenge: TChallenge; const Name, Value: string);
begin
  SetLength(Challenge.Parameters, Length(Challenge.Parameters) + 1);
  Challenge.Parameters[High(Challenge.Parameters)].Name := Name;
  Challenge.Parameters[High(Challenge.Parameters)].Value := Value;
end;

{ Token68 characters with "=" only as padding at the end. }
function IsToken68(const Text: string): Boolean;
var
  Body: string;
begin
  Body := Text;
  while (Body <> '') and (Body[Length(Body)] = '=') do
    SetLength(Body, Length(Body) - 1);
  Result := (Body <> '') and (Pos('=', Body) = 0);
end;

{ After the scheme: a token68 or parameters, up to the next scheme. }
procedure ReadParameters(var Reader: TChallengeReader; var Challenge: TChallenge);
var
  Saved, Start: Integer;
  Name: string;
begin
  SkipBlanks(Reader);
  { A token68 ("Basic dXNlcg=="): characters, maybe "=" padding, then
    a comma or the end. }
  Start := Reader.Position;
  while (Reader.Position <= Length(Reader.Text)) and (Reader.Text[Reader.Position] in Token68Characters) do
    Inc(Reader.Position);
  Saved := Reader.Position;
  SkipBlanks(Reader);
  if (CurrentCharacter(Reader) in [',', #0]) and IsToken68(Copy(Reader.Text, Start, Saved - Start)) then
  begin
    AddParameter(Challenge, '', Copy(Reader.Text, Start, Saved - Start));
    Exit;
  end;
  Reader.Position := Start;
  while True do
  begin
    SkipBlanksAndCommas(Reader);
    Saved := Reader.Position;
    Name := ReadToken(Reader);
    if Name = '' then
      Exit;
    SkipBlanks(Reader);
    if CurrentCharacter(Reader) <> '=' then
    begin
      { The start of the next challenge. }
      Reader.Position := Saved;
      Exit;
    end;
    Inc(Reader.Position);
    SkipBlanks(Reader);
    if CurrentCharacter(Reader) = '"' then
      AddParameter(Challenge, Name, ReadQuoted(Reader))
    else
      AddParameter(Challenge, Name, ReadToken(Reader));
  end;
end;

procedure ParseChallenges(const FieldValue: string; var Challenges: TChallengeArray);
var
  Reader: TChallengeReader;
  Challenge: TChallenge;
begin
  Reader.Text := FieldValue;
  Reader.Position := 1;
  while True do
  begin
    SkipBlanksAndCommas(Reader);
    Challenge := Default(TChallenge);
    Challenge.Scheme := ReadToken(Reader);
    if Challenge.Scheme = '' then
      Exit;
    ReadParameters(Reader, Challenge);
    SetLength(Challenges, Length(Challenges) + 1);
    Challenges[High(Challenges)] := Challenge;
  end;
end;

function ChallengeParameter(constref Challenge: TChallenge; const Name: string): string;
var
  Index: Integer;
begin
  for Index := 0 to High(Challenge.Parameters) do
    if SameText(Challenge.Parameters[Index].Name, Name) then
      Exit(Challenge.Parameters[Index].Value);
  Result := '';
end;

function ChallengeHasParameter(constref Challenge: TChallenge; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Challenge.Parameters) do
    if SameText(Challenge.Parameters[Index].Name, Name) then
      Exit(True);
  Result := False;
end;

end.
