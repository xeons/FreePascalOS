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
  One test in its own process (wptrun --child URL --seconds S --trust-ca
  FILE [-f FONTDIR]): a webbrowse session (WebBrowse.Session, the real
  pipeline on host sockets) with the test domains mapped to 127.0.0.1
  and WPT's CA trusted, the console echoed on standard output, done when
  the harness prints its report (WptRun.Results.ResultMarker) or the
  time is up.
}
unit WptRun.Child;

{$mode objfpc}
{$H+}

interface

{ The exit status of the child run (WebBrowse.Session.RunBrowse's). }
function RunChild: Integer;

implementation

uses
  SysUtils,
  WebBrowse.HostNetwork,
  WebBrowse.Session,
  WptRun.Results;

const
  TestDomain = 'web-platform.test';
  AlternateTestDomain = 'not-web-platform.test';
  LoopbackAddress = '127.0.0.1';

function RunChild: Integer;
var
  Options: TBrowseOptions;
  Index: Integer;
  Argument: string;
begin
  Options := DefaultBrowseOptions;
  Options.EchoConsole := True;
  Options.FinishMarker := ResultMarker;
  { Test pages loop on purpose at times; the run's own limit decides. }
  Options.StallSeconds := 60;
  Index := 1;
  while Index <= ParamCount do
  begin
    Argument := ParamStr(Index);
    if (Argument = '--child') and (Index < ParamCount) then
    begin
      Inc(Index);
      Options.Url := ParamStr(Index);
    end
    else if (Argument = '--seconds') and (Index < ParamCount) then
    begin
      Inc(Index);
      Options.TimeoutSeconds := StrToFloatDef(ParamStr(Index), 20);
    end
    else if (Argument = '--trust-ca') and (Index < ParamCount) then
    begin
      Inc(Index);
      TrustCertificateFile(ParamStr(Index));
    end
    else if (Argument = '-f') and (Index < ParamCount) then
    begin
      Inc(Index);
      Options.FontDirectory := ParamStr(Index);
    end;
    Inc(Index);
  end;
  MapHostToAddress(TestDomain, LoopbackAddress);
  MapHostToAddress(AlternateTestDomain, LoopbackAddress);
  Result := RunBrowse(Options);
end;

end.
