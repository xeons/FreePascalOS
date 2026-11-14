{
  Permission modes as chmod, mkdir -m and install -m accept them:

    755, 0644              octal
    u+x, go-w, a=r, u=rw,g=r,o=
    +X                     execute only for directories, or files that
                           already have some execute bit

  The mode bits are the usual Unix ones (0o7777: set-user-id, set-group-id,
  sticky, then rwx for user, group and others).
}
unit Util.Modes;

{$mode objfpc}
{$pointermath on}

interface

type
  { A parsed mode, applied later to each file's current mode. }
  TModeChange = record
    Text: PChar;
    IsOctal: Boolean;
    OctalValue: LongWord;
  end;

{ Returns False if Text is not a valid mode. }
function ParseModeChange(Text: PChar; out Change: TModeChange): Boolean;
{ The new mode for a file with CurrentMode. }
function ApplyModeChange(const Change: TModeChange; CurrentMode: LongWord; IsDirectory: Boolean): LongWord;
{ "rwxr-xr-x" (9 characters; Buffer needs 10). }
function FormatModeText(Mode: LongWord; Buffer: PChar): PChar;

implementation

uses
  Sys.Text;

const
  DefaultMask = $12; { the usual umask 022 }

function ParseModeChange(Text: PChar; out Change: TModeChange): Boolean;
var
  Position: Integer;
  Value: LongWord;
  Mode: LongWord;
begin
  Change.Text := Text;
  Change.IsOctal := False;
  Change.OctalValue := 0;
  if Text^ = #0 then
    Exit(False);

  if Text^ in ['0'..'7'] then
  begin
    Value := 0;
    Position := 0;
    while Text[Position] in ['0'..'7'] do
    begin
      Value := Value * 8 + LongWord(Ord(Text[Position]) - Ord('0'));
      Inc(Position);
    end;
    if (Text[Position] <> #0) or (Value > $FFF) then
      Exit(False);
    Change.IsOctal := True;
    Change.OctalValue := Value;
    Exit(True);
  end;

  { Validate the symbolic form by applying it once. }
  Position := 0;
  while Text[Position] <> #0 do
  begin
    while Text[Position] in ['u', 'g', 'o', 'a'] do
      Inc(Position);
    if not (Text[Position] in ['+', '-', '=']) then
      Exit(False);
    while Text[Position] in ['+', '-', '='] do
    begin
      Inc(Position);
      while Text[Position] in ['r', 'w', 'x', 'X', 's', 't', 'u', 'g', 'o'] do
        Inc(Position);
    end;
    if Text[Position] = ',' then
      Inc(Position)
    else if Text[Position] <> #0 then
      Exit(False);
  end;
  Mode := 0;
  Result := True;
end;

{ The rwx bits (in "user" position 0o700 scale 0..7) for who letters. }
function WhoMask(UserSelected, GroupSelected, OthersSelected: Boolean): LongWord;
begin
  Result := 0;
  if UserSelected then
    Result := Result or $9C0;   { 4700: setuid + rwx }
  if GroupSelected then
    Result := Result or $438;   { 2070: setgid + rwx }
  if OthersSelected then
    Result := Result or $207;   { 1007: sticky + rwx }
end;

{ Spreads an rwx value (0..7) to every selected class. }
function Spread(Bits: LongWord): LongWord;
begin
  Result := (Bits shl 6) or (Bits shl 3) or Bits;
end;

function ApplyModeChange(const Change: TModeChange; CurrentMode: LongWord; IsDirectory: Boolean): LongWord;
var
  Text: PChar;
  Position: Integer;
  UserSelected, GroupSelected, OthersSelected: Boolean;
  NoneGiven: Boolean;
  Operation: Char;
  Permissions: LongWord;
  Mask: LongWord;
  Affected: LongWord;
begin
  if Change.IsOctal then
    Exit(Change.OctalValue);
  Result := CurrentMode and $FFF;
  Text := Change.Text;
  Position := 0;
  while Text[Position] <> #0 do
  begin
    UserSelected := False;
    GroupSelected := False;
    OthersSelected := False;
    NoneGiven := True;
    while Text[Position] in ['u', 'g', 'o', 'a'] do
    begin
      case Text[Position] of
        'u': UserSelected := True;
        'g': GroupSelected := True;
        'o': OthersSelected := True;
        'a':
          begin
            UserSelected := True;
            GroupSelected := True;
            OthersSelected := True;
          end;
      end;
      NoneGiven := False;
      Inc(Position);
    end;
    if NoneGiven then
    begin
      UserSelected := True;
      GroupSelected := True;
      OthersSelected := True;
    end;
    Mask := WhoMask(UserSelected, GroupSelected, OthersSelected);

    while Text[Position] in ['+', '-', '='] do
    begin
      Operation := Text[Position];
      Inc(Position);
      Permissions := 0;
      while Text[Position] in ['r', 'w', 'x', 'X', 's', 't', 'u', 'g', 'o'] do
      begin
        case Text[Position] of
          'r': Permissions := Permissions or Spread(4);
          'w': Permissions := Permissions or Spread(2);
          'x': Permissions := Permissions or Spread(1);
          'X':
            if IsDirectory or ((Result and $49) <> 0) then
              Permissions := Permissions or Spread(1);
          's': Permissions := Permissions or $C00;
          't': Permissions := Permissions or $200;
          'u': Permissions := Permissions or Spread((Result shr 6) and 7);
          'g': Permissions := Permissions or Spread((Result shr 3) and 7);
          'o': Permissions := Permissions or Spread(Result and 7);
        end;
        Inc(Position);
      end;
      Affected := Permissions and Mask;
      { Without who letters, "+" and "=" respect the usual umask. }
      if NoneGiven and (Operation <> '-') then
        Affected := Affected and not DefaultMask;
      case Operation of
        '+': Result := Result or Affected;
        '-': Result := Result and not Affected;
        '=':
          begin
            { Directories keep set-id bits unless explicitly named. }
            if IsDirectory then
              Result := (Result and not (Mask and $1FF)) or Affected
            else
              Result := (Result and not Mask) or Affected;
          end;
      end;
    end;
    if Text[Position] = ',' then
      Inc(Position);
  end;
end;

function FormatModeText(Mode: LongWord; Buffer: PChar): PChar;
const
  Letters: array[0..8] of Char = ('r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x');
var
  Bit: Integer;
begin
  for Bit := 0 to 8 do
  begin
    if (Mode and (1 shl (8 - Bit))) <> 0 then
      Buffer[Bit] := Letters[Bit]
    else
      Buffer[Bit] := '-';
  end;
  { Special bits show in the execute positions. }
  if (Mode and $800) <> 0 then
    if Buffer[2] = 'x' then Buffer[2] := 's' else Buffer[2] := 'S';
  if (Mode and $400) <> 0 then
    if Buffer[5] = 'x' then Buffer[5] := 's' else Buffer[5] := 'S';
  if (Mode and $200) <> 0 then
    if Buffer[8] = 'x' then Buffer[8] := 't' else Buffer[8] := 'T';
  Buffer[9] := #0;
  Result := Buffer;
end;

end.
