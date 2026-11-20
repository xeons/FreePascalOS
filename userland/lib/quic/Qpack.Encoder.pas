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
  The QPACK encoder (RFC 9204), with the static table and literals only:
  it never inserts into the dynamic table, so its field sections start
  with Required Insert Count 0 and Base 0, never block a decoder, and
  need nothing from the decoder stream. Each field line is

    - the static entry when the whole line is there (Indexed, T=1),
    - its name from the static table and the value as a literal
      (Literal With Name Reference, T=1), or
    - name and value both as literals (Literal With Literal Name),

  each string Huffman coded when that is shorter. Names go out in lower
  case, as HTTP/3 wants (RFC 9114 section 4.2).
}
unit Qpack.Encoder;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Qpack.StaticTable;

function EncodeFieldSection(constref Fields: TQpackFieldList): TBytes;

implementation

uses
  Http.ByteBuffers,
  Qpack.Primitives;

function EncodeFieldSection(constref Fields: TQpackFieldList): TBytes;
var
  Output: TQpackOutput;
  Index, ExactIndex, NameIndex: Integer;
  Name: string;
begin
  Output := Default(TQpackOutput);
  { Required Insert Count 0, Base 0. }
  AppendByte(Output, 0);
  AppendByte(Output, 0);
  for Index := 0 to High(Fields) do
  begin
    Name := LowerCase(Fields[Index].Name);
    FindStaticEntry(Name, Fields[Index].Value, ExactIndex, NameIndex);
    if ExactIndex >= 0 then
      AppendPrefixedInteger(Output, $C0, 6, ExactIndex)
    else if NameIndex >= 0 then
    begin
      AppendPrefixedInteger(Output, $50, 4, NameIndex);
      AppendStringLiteral(Output, $00, 7, Fields[Index].Value);
    end
    else
    begin
      AppendStringLiteral(Output, $20, 3, Name);
      AppendStringLiteral(Output, $00, 7, Fields[Index].Value);
    end;
  end;
  Result := OutputBytes(Output);
end;

end.
