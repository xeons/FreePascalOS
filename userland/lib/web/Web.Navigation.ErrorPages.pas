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
  The documents a navigation shows when there is nothing of the site's
  to show: the network error page (the address, what went wrong, the
  cause libhttp or the fetch layer gave) and the page for a response
  the engine cannot display. Plain HTML with a little inline style, so
  it looks the same in the browser and in a web view.
}
unit Web.Navigation.ErrorPages;

{$mode objfpc}
{$H+}

interface

function NetworkErrorPage(const Url, Reason: string): string;
function CannotDisplayPage(const Url, MimeType: string): string;
function EscapeHtmlText(const Text: string): string;

implementation

uses
  SysUtils;

function EscapeHtmlText(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Text) do
    case Text[Index] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
    else
      Result := Result + Text[Index];
    end;
end;

function PageShell(const Title, Body: string): string;
begin
  Result := '<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + EscapeHtmlText(Title) + '</title>' +
    '<style>body{font-family:sans-serif;margin:3em auto;max-width:40em;padding:0 1em}' +
    'h1{font-size:1.4em}code{word-break:break-all}.reason{color:#555}</style></head><body>' + Body +
    '</body></html>';
end;

function NetworkErrorPage(const Url, Reason: string): string;
begin
  Result := PageShell('Cannot open the page', '<h1>This page cannot be opened</h1><p><code>' +
    EscapeHtmlText(Url) + '</code></p><p class="reason">' + EscapeHtmlText(Reason) + '</p>');
end;

function CannotDisplayPage(const Url, MimeType: string): string;
begin
  Result := PageShell('Cannot display the page', '<h1>This content cannot be shown</h1><p><code>' +
    EscapeHtmlText(Url) + '</code></p><p class="reason">The type ' + EscapeHtmlText(MimeType) +
    ' is not one the browser can display.</p>');
end;

end.
