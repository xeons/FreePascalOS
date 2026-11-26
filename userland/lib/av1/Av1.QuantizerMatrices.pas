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
  The quantizer matrices of the AV1 specification (section 10.4):
  Quantizer_Matrix[ level ][ plane type ][ position ], with the
  positions of each transform size starting at Qm_Offset (Av1.Tables).
  Written by make-tables.py into Av1.QuantizerMatrices.inc.
}
unit Av1.QuantizerMatrices;

{$mode objfpc}

interface

{$I Av1.QuantizerMatrices.inc}

implementation

end.
