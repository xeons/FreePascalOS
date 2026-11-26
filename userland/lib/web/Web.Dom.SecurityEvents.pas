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
  SecurityPolicyViolationEvent (CSP Level 3 section 5.1): what a
  securitypolicyviolation event says of a violation. Fired by the
  document's CSP reporter (Web.Loading.CspReports) at the element the
  violation is about, else at the document; script can make them too.
}
unit Web.Dom.SecurityEvents;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom.Events;

type
  TSecurityPolicyViolationEvent = class(TEvent)
  public
    DocumentUri: string;
    Referrer: string;
    BlockedUri: string;
    EffectiveDirective: string;
    ViolatedDirective: string;
    OriginalPolicy: string;
    SourceFile: string;
    Sample: string;
    { 'enforce' or 'report'. }
    Disposition: string;
    StatusCode: Word;
    LineNumber: LongWord;
    ColumnNumber: LongWord;
  end;

implementation

end.
