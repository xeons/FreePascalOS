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
  libdynpascal.so: a Free Pascal library for dynlibtest to load with
  LoadLibrary, with threadvars and a unit initialization of its own
  (DynPascalState). Built from this "library" source with the startup
  unit si_dll, linked with -init FPC_SHARED_LIB_START and -fini
  FPC_LIB_EXIT (userland.mk).
}
library DynPascal;

{$mode objfpc}

uses
  DynPascalState;

exports
  DynPascalCounterAddress name 'dynpascal_counter_address',
  DynPascalMark name 'dynpascal_mark',
  DynPascalSetMark name 'dynpascal_set_mark',
  DynPascalInitializations name 'dynpascal_initializations',
  DynPascalGreeting name 'dynpascal_greeting',
  DynPascalGreetingCopy name 'dynpascal_greeting_copy';

begin
end.
