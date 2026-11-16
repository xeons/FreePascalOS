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
  The bit reader of VP8L: bits are taken from each byte's least
  significant end first, numbers of several bits least significant bit
  first (as deflate's).

  Up to 64 bits wait in a window; PeekBits shows the next ones (zeros
  past the end of the data, so a prefix code can be looked up near the
  end), and taking more bits than the data holds is "cut short".
}
unit Image.WebP.LosslessBits;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors;

type
  TLosslessBitReader = class
  private
    FData: PByte;
    FSize: PtrInt;
    FPosition: PtrInt;
    FWindow: QWord;
    FBitCount: LongInt;
  public
    { Reads Size bytes at Data (which stay the caller's). }
    constructor Create(Data: PByte; Size: PtrInt);
    { Fills the window as far as the data goes. }
    procedure Refill; inline;
    { The next Count (at most 32) bits without taking them; call Refill
      first. }
    function PeekBits(Count: LongInt): LongWord; inline;
    { Takes Count bits that were peeked at. }
    procedure SkipBits(Count: LongInt); inline;
    function ReadBits(Count: LongInt): LongWord;
    function ReadBit: Boolean;
  end;

implementation

constructor TLosslessBitReader.Create(Data: PByte; Size: PtrInt);
begin
  inherited Create;
  FData := Data;
  FSize := Size;
  FPosition := 0;
  FWindow := 0;
  FBitCount := 0;
  Refill;
end;

procedure TLosslessBitReader.Refill;
begin
  while (FBitCount <= 56) and (FPosition < FSize) do
  begin
    FWindow := FWindow or (QWord(FData[FPosition]) shl FBitCount);
    Inc(FPosition);
    Inc(FBitCount, 8);
  end;
end;

function TLosslessBitReader.PeekBits(Count: LongInt): LongWord;
begin
  Result := LongWord(FWindow and ((QWord(1) shl Count) - 1));
end;

procedure TLosslessBitReader.SkipBits(Count: LongInt);
begin
  if Count > FBitCount then
    RaiseImageError(ImageErrorTruncated, 'VP8L data');
  FWindow := FWindow shr Count;
  Dec(FBitCount, Count);
end;

function TLosslessBitReader.ReadBits(Count: LongInt): LongWord;
begin
  if Count = 0 then
    Exit(0);
  Refill;
  Result := PeekBits(Count);
  SkipBits(Count);
end;

function TLosslessBitReader.ReadBit: Boolean;
begin
  Result := ReadBits(1) <> 0;
end;

end.
