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
  Recursive retrieval (-r) and page requisites (-p), breadth first as
  GNU wget goes:

  - each URL is fetched once, into the file Wget.LocalPaths names (an
    existing one is overwritten);
  - the links of a page (Wget.Links, resolved against its <base> or its
    final URL) are followed while its depth is below -l (5 by default,
    0 or inf: no limit), and its requisites (images, stylesheets,
    scripts) are fetched whatever the depth with -p;
  - only links to the host of the URL they came from are followed;
    with -np none above the folder the recursion started in;
  - robots.txt is asked first on each server and respected, unless
    "-e robots=off";
  - -A/-R decide by file name; a page they reject is still fetched for
    its links, then removed, as GNU wget does;
  - with -k the pages' links are converted at the end (Wget.Converter).

  Returns the exit status: success, or that of the last failure.
}
unit Wget.Recursion;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Sessions,
  Wget.Urls;

function RetrieveRecursively(Session: TWgetSession; const StartUrls: array of TUrl): Integer;

implementation

uses
  Classes,
  SysUtils,
  StrUtils,
  Sys.Streams,
  Wget.Converter,
  Wget.Downloads,
  Wget.FileText,
  Wget.Links,
  Wget.LocalPaths,
  Wget.Patterns,
  Wget.RobotsCache,
  Wget.Settings,
  Wget.Transfer;

type
  TQueueItem = record
    Url: TUrl;
    Depth: Integer;
    IsRequisite: Boolean;
    { The URL whose page linked here (for -np and the host). }
    StartFolder: string;
  end;

  TRecursion = record
    Session: TWgetSession;
    Settings: TWgetSettings;
    Layout: TLocalLayout;
    Queue: array of TQueueItem;
    QueueHead: Integer;
    Seen: TStringList;
    Downloads: TDownloadList;
    Robots: TRobotsCache;
    ExitStatus: Integer;
  end;

function UrlText(constref Url: TUrl): string;
begin
  Result := FormatUrl(Url);
end;

{ The folder of a URL's path ("/a/b/c.html" -> "/a/b/"). }
function PathFolder(constref Url: TUrl): string;
var
  Path: string;
  QueryStart: Integer;
begin
  Path := Url.Path;
  QueryStart := Pos('?', Path);
  if QueryStart > 0 then
    SetLength(Path, QueryStart - 1);
  Result := Copy(Path, 1, RPos('/', Path));
end;

{ The last segment of the path, as -A and -R see it. }
function FileNameOf(constref Url: TUrl): string;
begin
  Result := DefaultFileName(Url);
end;

{ The URL may lead to a page (whose links are wanted even if -A/-R
  reject the file). }
function MayBePage(constref Url: TUrl): Boolean;
var
  Name: string;
begin
  Name := LowerCase(FileNameOf(Url));
  Result := (PathFolder(Url) = Url.Path) or EndsStr('.html', Name) or EndsStr('.htm', Name) or
    EndsStr('.xhtml', Name) or (Pos('.', Name) = 0);
end;

function IsPage(constref Outcome: TFetchResult): Boolean;
var
  ContentType: string;
begin
  ContentType := LowerCase(Outcome.ContentType);
  if ContentType <> '' then
    Exit(StartsStr('text/html', ContentType) or StartsStr('application/xhtml+xml', ContentType));
  Result := EndsText('.html', Outcome.FileName) or EndsText('.htm', Outcome.FileName);
end;

procedure Enqueue(var Recursion: TRecursion; constref Url: TUrl; Depth: Integer; IsRequisite: Boolean;
  const StartFolder: string);
var
  Item: TQueueItem;
begin
  if Recursion.Seen.IndexOf(UrlText(Url)) >= 0 then
    Exit;
  Recursion.Seen.Add(UrlText(Url));
  Item.Url := Url;
  Item.Depth := Depth;
  Item.IsRequisite := IsRequisite;
  Item.StartFolder := StartFolder;
  SetLength(Recursion.Queue, Length(Recursion.Queue) + 1);
  Recursion.Queue[High(Recursion.Queue)] := Item;
end;

function DepthAllowsFollowing(constref Recursion: TRecursion; constref Item: TQueueItem): Boolean;
begin
  Result := Recursion.Settings.Recursive and not Item.IsRequisite and
    ((Recursion.Settings.MaximumDepth = 0) or (Item.Depth < Recursion.Settings.MaximumDepth));
end;

{ Whether a link found on the page of From is to be fetched. }
function LinkIsWanted(var Recursion: TRecursion; constref From: TQueueItem; constref Target: TUrl;
  IsRequisite: Boolean): Boolean;
begin
  Result := False;
  if not SameText(Target.Host, From.Url.Host) then
    Exit;
  if not IsRequisite and Recursion.Settings.NoParent and
     (Copy(Target.Path, 1, Length(From.StartFolder)) <> From.StartFolder) then
    Exit;
  if not FileNameAccepted(Recursion.Settings.AcceptList, Recursion.Settings.RejectList, FileNameOf(Target)) and
     not MayBePage(Target) then
    Exit;
  if Recursion.Settings.RespectRobots and not Recursion.Robots.Allows(Target) then
    Exit;
  Result := True;
end;

{ The links of a fetched page into the queue. }
procedure QueueLinks(var Recursion: TRecursion; constref Item: TQueueItem; constref Outcome: TFetchResult);
var
  Html: string;
  Links: TFoundLinkArray;
  Link: TFoundLink;
  Base, Target: TUrl;
  Reference: string;
  Hash: Integer;
  Follow: Boolean;
begin
  if not ReadFileText(Outcome.FileName, Html) then
    Exit;
  Links := ExtractLinks(Html);
  Base := Outcome.FinalUrl;
  if (FindBaseReference(Links) <> '') and not ResolveUrl(Outcome.FinalUrl, FindBaseReference(Links), Base) then
    Base := Outcome.FinalUrl;
  Follow := DepthAllowsFollowing(Recursion, Item);
  for Link in Links do
  begin
    if Link.Kind = LinkBase then
      Continue;
    if (Link.Kind = LinkRequisite) and not Recursion.Settings.PageRequisites and not Follow then
      Continue;
    if (Link.Kind = LinkFollowed) and not Follow then
      Continue;
    Reference := Link.Reference;
    Hash := Pos('#', Reference);
    if Hash > 0 then
      SetLength(Reference, Hash - 1);
    if (Reference = '') or not ResolveUrl(Base, Reference, Target) then
      Continue;
    if not LinkIsWanted(Recursion, Item, Target, Link.Kind = LinkRequisite) then
      Continue;
    Enqueue(Recursion, Target, Item.Depth + 1, (Link.Kind = LinkRequisite) and not Follow, Item.StartFolder);
  end;
end;

procedure RetrieveItem(var Recursion: TRecursion; constref Item: TQueueItem);
var
  Request: TFetchRequest;
  Outcome: TFetchResult;
  Page: Boolean;
begin
  Request := Default(TFetchRequest);
  Request.Url := Item.Url;
  Request.HasOutput := True;
  Request.Output := LocalPathFor(Item.Url, Recursion.Layout);
  MakeFolders(FolderOf(Request.Output));
  FetchUrl(Recursion.Session, Request, Outcome);
  if not Outcome.Saved then
  begin
    if Outcome.ExitStatus <> ExitSuccess then
      Recursion.ExitStatus := Outcome.ExitStatus;
    Exit;
  end;
  Page := IsPage(Outcome);
  if Page then
    QueueLinks(Recursion, Item, Outcome);
  if not FileNameAccepted(Recursion.Settings.AcceptList, Recursion.Settings.RejectList, FileNameOf(Item.Url)) then
  begin
    if not Recursion.Settings.Quiet then
      PrintErrorString(Format('Removing %s since it should be rejected.'#10#10, [Request.Output]));
    RemoveFile(Request.Output);
    Exit;
  end;
  Recursion.Downloads.Add(Item.Url, Outcome.FinalUrl, Request.Output, Page);
end;

function RetrieveRecursively(Session: TWgetSession; const StartUrls: array of TUrl): Integer;
var
  Recursion: TRecursion;
  Url: TUrl;
  Item: TQueueItem;
begin
  Recursion := Default(TRecursion);
  Recursion.Session := Session;
  Recursion.Settings := Session.Settings;
  Recursion.Layout.Prefix := Session.Settings.DirectoryPrefix;
  Recursion.Layout.NoHostFolder := Session.Settings.NoHostFolder;
  Recursion.Layout.NoFolders := Session.Settings.NoFolders;
  Recursion.ExitStatus := ExitSuccess;
  Recursion.Seen := TStringList.Create;
  Recursion.Seen.Sorted := True;
  Recursion.Seen.CaseSensitive := True;
  Recursion.Downloads := TDownloadList.Create;
  Recursion.Robots := TRobotsCache.Create(Session, Recursion.Layout);
  try
    for Url in StartUrls do
      Enqueue(Recursion, Url, 0, False, PathFolder(Url));
    while Recursion.QueueHead < Length(Recursion.Queue) do
    begin
      Item := Recursion.Queue[Recursion.QueueHead];
      Inc(Recursion.QueueHead);
      RetrieveItem(Recursion, Item);
    end;
    if Recursion.Settings.ConvertLinks then
      ConvertDownloadedLinks(Recursion.Downloads, Recursion.Settings.Quiet);
  finally
    Recursion.Robots.Free;
    Recursion.Downloads.Free;
    Recursion.Seen.Free;
  end;
  Result := Recursion.ExitStatus;
end;

end.
