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
  Walking IPv6's extension headers (RFC 8200 4) from the fixed header
  to the upper-layer protocol.

  Hop-by-hop options (only right after the fixed header) and
  destination options are looked through: padding and the router alert
  are known; an unknown option is skipped, or the datagram dropped (with
  a parameter problem for the sender) as the option's two high bits
  say. A routing header is passed over when no segments are left, else
  refused (nothing is forwarded). A fragment header ends the walk
  unless it is an atomic fragment (offset 0, no more fragments), which
  is passed over. "No next header" ends it with nothing to deliver.

  The first fragment of a datagram must hold the whole header chain up
  to and with the upper-layer header (RFC 8200 4.5, RFC 7112):
  FirstFragmentHoldsHeaderChain says whether it does.
}
unit Network.Ipv6Headers;

{$mode objfpc}
{$pointermath on}

interface

type
  TIpv6WalkOutcome = (
    { Offset is where the upper-layer data (NextHeader's) begins. }
    WalkReachedUpperLayer,
    { Offset is where the fragment header begins. }
    WalkReachedFragment,
    { The sender should get a parameter problem (ProblemCode at
      ProblemPointer). }
    WalkParameterProblem,
    { Dropped without a word: damaged, or nothing follows. }
    WalkMalformed);

  TIpv6HeaderWalk = record
    Outcome: TIpv6WalkOutcome;
    { The upper-layer protocol; for a fragment, what the fragment
      header says follows it. }
    NextHeader: Byte;
    { Where the byte holding NextHeader is (from the fixed header). }
    NextHeaderPointer: LongWord;
    Offset: LongWord;
    { A fragment: its place in the original payload, whether more
      follow, and the original datagram's identification. }
    FragmentOffset: LongWord;
    MoreFragments: Boolean;
    Identification: LongWord;
    ProblemCode: Byte;
    ProblemPointer: LongWord;
  end;

{ Walks the datagram at Data (the fixed header first, TotalLength bytes
  in all). }
function WalkIpv6Headers(Data: PByte; TotalLength: LongWord): TIpv6HeaderWalk;
{ The Length bytes at Data, the fragmentable part of a first fragment
  whose fragment header names NextHeader, hold every extension header
  that follows and the upper-layer header (TCP 20 bytes, UDP 8, ICMPv6
  4; an unknown or encrypted protocol is taken as it is). }
function FirstFragmentHoldsHeaderChain(Data: PByte; Length: LongWord; NextHeader: Byte): Boolean;

implementation

uses
  Runtime.Memory,
  Network.ByteOrder;

const
  FixedHeaderBytes = 40;
  FragmentHeaderBytes = 8;
  NextHeaderHopByHop = 0;
  NextHeaderRouting = 43;
  NextHeaderFragment = 44;
  NextHeaderNone = 59;
  NextHeaderDestinationOptions = 60;
  NextHeaderAuthentication = 51;
  NextHeaderTcp = 6;
  NextHeaderUdp = 17;
  NextHeaderIcmpv6 = 58;
  OptionPad1 = 0;
  OptionPadN = 1;
  OptionRouterAlert = 5;
  ProblemErroneousField = 0;
  ProblemUnknownNextHeader = 1;
  ProblemUnknownOption = 2;

procedure SetProblem(var Walk: TIpv6HeaderWalk; Code: Byte; Pointer: LongWord);
begin
  Walk.Outcome := WalkParameterProblem;
  Walk.ProblemCode := Code;
  Walk.ProblemPointer := Pointer;
end;

{ Looks through the options of a hop-by-hop or destination options
  header of HeaderLength bytes at Offset; False (and Walk says what
  became of the datagram) if one of them means dropping it. }
function CheckOptions(Data: PByte; Offset, HeaderLength: LongWord; var Walk: TIpv6HeaderWalk): Boolean;
var
  Position: LongWord;
  OptionType: Byte;
  OptionLength: LongWord;
begin
  Position := Offset + 2;
  while Position < Offset + HeaderLength do
  begin
    OptionType := Data[Position];
    if OptionType = OptionPad1 then
    begin
      Inc(Position);
      Continue;
    end;
    if Position + 1 >= Offset + HeaderLength then
    begin
      Walk.Outcome := WalkMalformed;
      Exit(False);
    end;
    OptionLength := 2 + LongWord(Data[Position + 1]);
    if Position + OptionLength > Offset + HeaderLength then
    begin
      SetProblem(Walk, ProblemErroneousField, Position + 1);
      Exit(False);
    end;
    if not (OptionType in [OptionPadN, OptionRouterAlert]) then
      case OptionType shr 6 of
        1:
          begin
            Walk.Outcome := WalkMalformed;
            Exit(False);
          end;
        2, 3:
          begin
            SetProblem(Walk, ProblemUnknownOption, Position);
            Exit(False);
          end;
      end;
    Position := Position + OptionLength;
  end;
  Result := True;
end;

function WalkIpv6Headers(Data: PByte; TotalLength: LongWord): TIpv6HeaderWalk;
var
  NextHeader: Byte;
  Offset: LongWord;
  HeaderLength: LongWord;
  FragmentField: Word;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  NextHeader := Data[6];
  Result.NextHeaderPointer := 6;
  Offset := FixedHeaderBytes;
  repeat
    Result.NextHeader := NextHeader;
    Result.Offset := Offset;
    case NextHeader of
      NextHeaderHopByHop, NextHeaderDestinationOptions, NextHeaderRouting:
        begin
          if (NextHeader = NextHeaderHopByHop) and (Offset <> FixedHeaderBytes) then
          begin
            SetProblem(Result, ProblemUnknownNextHeader, Result.NextHeaderPointer);
            Exit;
          end;
          if Offset + 8 > TotalLength then
          begin
            Result.Outcome := WalkMalformed;
            Exit;
          end;
          HeaderLength := (LongWord(Data[Offset + 1]) + 1) * 8;
          if Offset + HeaderLength > TotalLength then
          begin
            SetProblem(Result, ProblemErroneousField, Offset + 1);
            Exit;
          end;
          if NextHeader = NextHeaderRouting then
          begin
            { Segments left: we would have to forward it. }
            if Data[Offset + 3] <> 0 then
            begin
              SetProblem(Result, ProblemErroneousField, Offset + 2);
              Exit;
            end;
          end
          else if not CheckOptions(Data, Offset, HeaderLength, Result) then
            Exit;
          NextHeader := Data[Offset];
          Result.NextHeaderPointer := Offset;
          Offset := Offset + HeaderLength;
        end;
      NextHeaderFragment:
        begin
          if Offset + FragmentHeaderBytes > TotalLength then
          begin
            Result.Outcome := WalkMalformed;
            Exit;
          end;
          FragmentField := ReadBigEndian16(Data + Offset + 2);
          Result.FragmentOffset := FragmentField and $FFF8;
          Result.MoreFragments := (FragmentField and 1) <> 0;
          Result.Identification := ReadBigEndian32(Data + Offset + 4);
          NextHeader := Data[Offset];
          Result.NextHeaderPointer := Offset;
          if (Result.FragmentOffset <> 0) or Result.MoreFragments then
          begin
            Result.NextHeader := NextHeader;
            Result.Outcome := WalkReachedFragment;
            Exit;
          end;
          Offset := Offset + FragmentHeaderBytes;
        end;
      NextHeaderNone:
        begin
          Result.Outcome := WalkMalformed;
          Exit;
        end;
    else
      Result.Outcome := WalkReachedUpperLayer;
      Exit;
    end;
  until False;
end;

function FirstFragmentHoldsHeaderChain(Data: PByte; Length: LongWord; NextHeader: Byte): Boolean;
var
  Position: LongWord;
  HeaderLength: LongWord;
begin
  Position := 0;
  repeat
    case NextHeader of
      NextHeaderHopByHop, NextHeaderRouting, NextHeaderDestinationOptions, NextHeaderAuthentication:
        begin
          if Position + 2 > Length then
            Exit(False);
          if NextHeader = NextHeaderAuthentication then
            HeaderLength := (LongWord(Data[Position + 1]) + 2) * 4
          else
            HeaderLength := (LongWord(Data[Position + 1]) + 1) * 8;
          if Position + HeaderLength > Length then
            Exit(False);
          NextHeader := Data[Position];
          Position := Position + HeaderLength;
        end;
      NextHeaderFragment:
        begin
          if Position + FragmentHeaderBytes > Length then
            Exit(False);
          NextHeader := Data[Position];
          Position := Position + FragmentHeaderBytes;
        end;
      NextHeaderTcp:
        Exit(Position + 20 <= Length);
      NextHeaderUdp:
        Exit(Position + 8 <= Length);
      NextHeaderIcmpv6:
        Exit(Position + 4 <= Length);
    else
      Exit(True);
    end;
  until False;
end;

end.
