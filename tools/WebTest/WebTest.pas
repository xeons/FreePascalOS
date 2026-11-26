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
  WebTest - checks libweb on the host (make web-test): HTML tree
  construction against the html5lib-format cases in a directory (whole
  and byte by byte), the encodings, the DOM (mutation algorithms,
  validity checks, collections, attributes, lifetime), event dispatch,
  serialization, the parser's script hooks, random documents (whole and
  byte by byte), the parser's speed and memory per node for a
  generated document, and IndexedDB's storage service.

    WebTest <tree construction directory>

  Prints one line per check and the totals; exits with 1 if any failed.
}
program WebTest;

{$mode objfpc}
{$H+}

uses
  TestChecks,
  WebTest.TreeConstruction,
  WebTest.Encoding,
  WebTest.Dom,
  WebTest.Events,
  WebTest.Serialization,
  WebTest.Fuzz,
  WebTest.Performance,
  WebTest.IndexedDb;

begin
  if ParamCount >= 1 then
    RunTreeConstructionTests(ParamStr(1))
  else
    RunTreeConstructionTests('tools/WebTest/tree-construction');
  RunEncodingTests;
  RunDomTests;
  RunEventTests;
  RunSerializationTests;
  RunFuzzTests;
  RunPerformanceTests;
  RunIndexedDbTests;
  FinishChecks('web test');
end.
