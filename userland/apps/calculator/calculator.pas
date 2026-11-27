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
  calculator - a desktop calculator

  calculator [-k KEYS]

  A window with the number shown in large type, the expression above
  it, and a keypad for one of three modes (View menu, Alt+1 to Alt+3):
  standard (left to right, as a pocket calculator), scientific
  (precedence and parentheses, trigonometry in degrees, radians or
  gradians, powers, roots, logarithms, factorials, pi and e) and
  programmer (integers of 8 to 64 bits in hexadecimal, decimal, octal
  or binary, and, or, xor, not, shifts). Memory (MC, MR, M+, M-, MS),
  a history of what was calculated beside the keypad (Ctrl+H), copy and
  paste of the number (Ctrl+C, Ctrl+V: a pasted expression is
  evaluated). The keyboard types everything (numpad included): Enter
  is equals, Escape clears, Delete clears the entry. Numbers show 15
  significant digits, so binary fractions do not show (0.1 + 0.2 is
  0.3). The mode and its options are kept in the user's settings (group
  Calculator).

    -k KEYS   types KEYS (Calculator.Actions' characters, "=" for
              Enter) as soon as the window is up

  Prints what happens, a line each:

    settings mode M, angles A, base B, word W, history on|off
    display TEXT        the number shown after a key or button
    result EXPR = TEXT  Equals evaluated an expression
    mode M, angles A, base B display TEXT, word W display TEXT,
    history on|off      an option chosen
    copied TEXT, pasted TEXT, paste refused
    exit

  The units are in userland/apps/calculator: Calculator.Numbers (showing and
  reading numbers), Calculator.MathFunctions, Calculator.Expressions
  (evaluating), Calculator.Engine (the keys' logic), Calculator.Actions
  (buttons and characters), Calculator.Display, Calculator.Keypad,
  Calculator.MainWindow, Calculator.Settings and Calculator.Output.
}
program Calculator;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Windowing.Windows,
  Calculator.Actions,
  Calculator.MainWindow;

var
  Window: TCalculatorWindow;
  Index: LongInt;
  Keys: string;
begin
  Keys := '';
  Index := 1;
  while Index <= ParamCount do
  begin
    if (ParamStr(Index) = '-k') and (Index < ParamCount) then
    begin
      Keys := ParamStr(Index + 1);
      Inc(Index);
    end;
    Inc(Index);
  end;
  Window := TCalculatorWindow.Create;
  Window.Show;
  for Index := 1 to Length(Keys) do
    Window.TypeCharacter(Ord(Keys[Index]));
  RunMessageLoop;
end.
