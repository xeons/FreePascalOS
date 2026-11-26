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
  The AV1 decoder's integer constants: the ones of the specification's
  section 3 and the values of its syntax elements (Av1.Constants.inc,
  written by make-tables.py), and a few the specification only names in
  prose.
}
unit Av1.Constants;

{$mode objfpc}

interface

{$I Av1.Constants.inc}

const
  { RefFrame[ 1 ] of a block with a single reference. }
  NONE = -1;

  CFL_SIGN_ZERO = 0;
  CFL_SIGN_NEG = 1;
  CFL_SIGN_POS = 2;

  TX_SET_DCTONLY = 0;
  TX_SET_INTRA_1 = 1;
  TX_SET_INTRA_2 = 2;
  TX_SET_INTER_1 = 1;
  TX_SET_INTER_2 = 2;
  TX_SET_INTER_3 = 3;

  OBU_SEQUENCE_HEADER = 1;

implementation

end.
