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
  -k: once a recursion is done, the links of every page it saved are
  made to work from the disk, as GNU wget does: a link to a file that
  was fetched becomes a relative link to it (its fragment kept), and a
  relative link to one that was not becomes the absolute URL, so it
  still leads to the server. Absolute links to what was not fetched
  stay as they are.
}
unit Wget.Converter;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Downloads;

{ Converts the pages of Downloads; Quiet says nothing. }
procedure ConvertDownloadedLinks(Downloads: TDownloadList; Quiet: Boolean);

implementation

uses
  SysUtils,
  StrUtils,
  Sys.Streams,
  Sys.Time,
  Wget.FileText,
  Wget.LinkConversion,
  Wget.Links,
  Wget.LocalPaths,
  Wget.Urls;

{ "page.html#part": the reference and "#part" apart. }
procedure SplitFragment(const Reference: string; out WithoutFragment, Fragment: string);
var
  Hash: Integer;
begin
  Hash := Pos('#', Reference);
  if Hash = 0 then
  begin
    WithoutFragment := Reference;
    Fragment := '';
  end
  else
  begin
    WithoutFragment := Copy(Reference, 1, Hash - 1);
    Fragment := Copy(Reference, Hash, MaxInt);
  end;
end;

function IsAbsoluteReference(const Reference: string): Boolean;
begin
  Result := StartsText('http://', Reference) or StartsText('https://', Reference) or StartsStr('//', Reference);
end;

{ The page's links with their replacements; how many were changed. }
function ConvertPage(Downloads: TDownloadList; constref Page: TDownload; const Html: string;
  out Converted: string): Integer;
var
  Links: TFoundLinkArray;
  Replacements: array of string;
  Base, Target: TUrl;
  Index: Integer;
  Reference, Fragment, LocalPath: string;
begin
  Result := 0;
  Links := ExtractLinks(Html);
  SetLength(Replacements, Length(Links));
  Base := Page.Url;
  if (FindBaseReference(Links) <> '') and not ResolveUrl(Page.Url, FindBaseReference(Links), Base) then
    Base := Page.Url;
  for Index := 0 to High(Links) do
  begin
    Replacements[Index] := '';
    if Links[Index].Kind = LinkBase then
      Continue;
    SplitFragment(Links[Index].Reference, Reference, Fragment);
    if (Reference = '') or not ResolveUrl(Base, Reference, Target) then
      Continue;
    if Downloads.FindLocalPath(Target, LocalPath) then
      Replacements[Index] := EscapeLinkPath(RelativeLink(Page.LocalPath, LocalPath)) + Fragment
    else if not IsAbsoluteReference(Reference) then
      Replacements[Index] := FormatUrl(Target) + Fragment;
    if Replacements[Index] = Links[Index].Reference then
      Replacements[Index] := ''
    else if Replacements[Index] <> '' then
      Inc(Result);
  end;
  Converted := ReplaceLinks(Html, Links, Replacements);
end;

procedure ConvertDownloadedLinks(Downloads: TDownloadList; Quiet: Boolean);
var
  Index: Integer;
  Page: TDownload;
  Html, Converted: string;
  Files: Integer;
  Started: QWord;
  Changed: Integer;
begin
  Files := 0;
  Started := UptimeMilliseconds;
  for Index := 0 to Downloads.Count - 1 do
  begin
    Page := Downloads.Downloads[Index];
    if not Page.IsPage or not ReadFileText(Page.LocalPath, Html) then
      Continue;
    Changed := ConvertPage(Downloads, Page, Html, Converted);
    if not Quiet then
      PrintErrorString(Format('Converting links in %s... %d.'#10, [Page.LocalPath, Changed]));
    if (Changed > 0) and not WriteFileText(Page.LocalPath, Converted) then
      PrintErrorString(Format('wget: cannot write ''%s''.'#10, [Page.LocalPath]));
    Inc(Files);
  end;
  if not Quiet then
    PrintErrorString(Format('Converted links in %d files in %d seconds.'#10, [Files,
      (UptimeMilliseconds - Started) div 1000]));
end;

end.
