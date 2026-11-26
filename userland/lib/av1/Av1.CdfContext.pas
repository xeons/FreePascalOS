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
  The adaptive cumulative distribution functions of the symbol decoder.

  TCdfContext holds every CDF array the specification names in the
  semantics of init_non_coeff_cdfs and init_coeff_cdfs (the fields are
  the specification's names without the Tile/Saved prefixes, written by
  make-tables.py into Av1.CdfFields.inc). A frame keeps one (the CDFs it
  starts with), each tile a copy it adapts, and each reference slot the
  one saved with its frame. Each CDF of N symbols is N + 1 words: the
  cumulative probabilities (the last one 32768) and the count of symbols
  decoded with it.
}
unit Av1.CdfContext;

{$mode objfpc}

interface

uses
  Av1.DefaultCdfs;

type
  TCdfContext = record
{$I Av1.CdfFields.inc}
  end;
  PCdfContext = ^TCdfContext;

{ init_non_coeff_cdfs: the CDFs not used by coeff( ) set to their defaults. }
procedure InitializeNonCoefficientCdfs(var Context: TCdfContext);
{ init_coeff_cdfs: the coefficient CDFs for the quantizer context Index (0..3). }
procedure InitializeCoefficientCdfs(var Context: TCdfContext; Index: Integer);
{ The symbol counts (the last entry of each CDF) set to 0, as load_cdfs does. }
procedure ClearCdfCounters(var Context: TCdfContext);
{ The quantizer context of init_coeff_cdfs for base_q_idx. }
function CoefficientCdfIndex(BaseQIndex: Integer): Integer;

implementation

procedure ClearCounters(First: PWord; Count, Length: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    First[Index * Length + Length - 1] := 0;
end;

{$I Av1.CdfInitialization.inc}

function CoefficientCdfIndex(BaseQIndex: Integer): Integer;
begin
  if BaseQIndex <= 20 then
    Result := 0
  else if BaseQIndex <= 60 then
    Result := 1
  else if BaseQIndex <= 120 then
    Result := 2
  else
    Result := 3;
end;

end.
