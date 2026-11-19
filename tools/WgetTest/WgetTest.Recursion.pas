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
  What wget's recursion is made of, on the host: the links of HTML
  pages (kinds, positions, references, comments and scripts skipped),
  robots.txt, the accept and reject lists, the local file names and
  the relative links between them, and converting links in place.
}
unit WgetTest.Recursion;

{$mode objfpc}
{$H+}

interface

procedure TestRecursion;

implementation

uses
  SysUtils,
  TestChecks,
  Wget.LinkConversion,
  Wget.Links,
  Wget.LocalPaths,
  Wget.Patterns,
  Wget.Robots,
  Wget.Urls;

const
  Page = '<!DOCTYPE html>'#10 +
    '<html><head><base href="http://example.com/base/">'#10 +
    '<link rel="stylesheet" href="style.css">'#10 +
    '<link rel="alternate" href="feed.xml">'#10 +
    '<LINK REL="Shortcut Icon" HREF=/favicon.ico>'#10 +
    '<script src="app.js"></script>'#10 +
    '<script>var s = "<a href=''not-a-link.html''>";</script>'#10 +
    '<style>body { background: url(x.png) }</style>'#10 +
    '<meta http-equiv="Refresh" content="5; URL=next.html">'#10 +
    '</head><body background="bg.gif">'#10 +
    '<!-- <a href="commented.html"> -->'#10 +
    '<a href="page2.html">two</a> <a href=''single.html''>s</a> <a href=bare.html>b</a>'#10 +
    '<a href="  spaced.html  ">x</a> <a href="q.cgi?a=1&amp;b=2">q</a> <a href="#top">top</a>'#10 +
    '<a href="mailto:me@example.com">m</a> <a href="javascript:void(0)">j</a>'#10 +
    '<img src="pic.png" alt="a > b"> <iframe src="frame.html"></iframe>'#10 +
    '<area href="map.html"> <object data="movie.swf"></object> <a name="anchor">no href</a>'#10 +
    '<a href="&#x2F;root&#47;x.html">r</a>'#10 +
    '</body></html>'#10;

function FindLink(const Links: TFoundLinkArray; const Reference: string; out Link: TFoundLink): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Links) do
    if Links[Index].Reference = Reference then
    begin
      Link := Links[Index];
      Exit(True);
    end;
  Link := Default(TFoundLink);
  Result := False;
end;

procedure CheckLink(const Links: TFoundLinkArray; const Reference: string; Kind: TLinkKind; const Name: string);
var
  Link: TFoundLink;
begin
  Check(FindLink(Links, Reference, Link) and (Link.Kind = Kind), Name);
end;

procedure TestLinks;
var
  Links: TFoundLinkArray;
  Link: TFoundLink;
begin
  Links := ExtractLinks(Page);
  Check(FindBaseReference(Links) = 'http://example.com/base/', 'links: the base');
  CheckLink(Links, 'style.css', LinkRequisite, 'links: a stylesheet is a requisite');
  CheckLink(Links, 'feed.xml', LinkFollowed, 'links: another link rel is followed');
  CheckLink(Links, '/favicon.ico', LinkRequisite, 'links: an icon, upper case, bare value');
  CheckLink(Links, 'app.js', LinkRequisite, 'links: a script');
  CheckLink(Links, 'next.html', LinkFollowed, 'links: a refresh');
  CheckLink(Links, 'bg.gif', LinkRequisite, 'links: a background');
  CheckLink(Links, 'page2.html', LinkFollowed, 'links: a href in double quotes');
  CheckLink(Links, 'single.html', LinkFollowed, 'links: single quotes');
  CheckLink(Links, 'bare.html', LinkFollowed, 'links: a bare value');
  CheckLink(Links, 'spaced.html', LinkFollowed, 'links: blanks around the value left out');
  CheckLink(Links, 'q.cgi?a=1&b=2', LinkFollowed, 'links: character references decoded');
  CheckLink(Links, 'pic.png', LinkRequisite, 'links: an image (with > in another attribute)');
  CheckLink(Links, 'frame.html', LinkFollowed, 'links: an iframe');
  CheckLink(Links, 'map.html', LinkFollowed, 'links: an area');
  CheckLink(Links, 'movie.swf', LinkRequisite, 'links: an object');
  CheckLink(Links, '/root/x.html', LinkFollowed, 'links: numeric references');
  Check(not FindLink(Links, 'not-a-link.html', Link), 'links: none inside a script');
  Check(not FindLink(Links, 'commented.html', Link), 'links: none inside a comment');
  Check(not FindLink(Links, 'x.png', Link), 'links: none inside a style element');
  Check(not FindLink(Links, '#top', Link), 'links: a fragment alone is left out');
  Check(not FindLink(Links, 'mailto:me@example.com', Link) and not FindLink(Links, 'javascript:void(0)', Link),
    'links: mailto and javascript are left out');
  Check(Length(Links) = 17, 'links: seventeen in all, the base among them');
  Check(FindLink(Links, 'spaced.html', Link) and (Copy(Page, Link.ValueStart, Link.ValueLength) = 'spaced.html'),
    'links: the position of a value without its blanks');
  Check(FindLink(Links, 'q.cgi?a=1&b=2', Link) and
    (Copy(Page, Link.ValueStart, Link.ValueLength) = 'q.cgi?a=1&amp;b=2'), 'links: the position of the raw value');
  Check(FindLink(Links, 'next.html', Link) and (Copy(Page, Link.ValueStart, Link.ValueLength) = 'next.html'),
    'links: the position of a refresh URL');
  Check(DecodeCharacterReferences('a&lt;b&gt;&quot;&apos;&#233;&bogus;&') = 'a<b>"''' + #$C3#$A9 + '&bogus;&',
    'links: references decoded, unknown ones left');
  Check(Length(ExtractLinks('<a href="unterminated')) = 1, 'links: an attribute running to the end');
  Check(Length(ExtractLinks('<<<>>> <a') ) = 0, 'links: junk');
end;

procedure TestRobots;
const
  Robots = '# comment'#10 +
    'User-agent: Googlebot'#10 +
    'Disallow: /'#10 +
    #10 +
    'User-agent: *'#10 +
    'Disallow: /cgi-bin/'#10 +
    'Disallow: /private'#10 +
    'Allow: /private/open.html'#10 +
    'Disallow: /*.pdf$'#10 +
    'Disallow:'#10;
  ForWget = 'User-agent: other'#10 +
    'User-agent: Wget/1.21'#10 +
    'Disallow: /only-for-wget/'#10 +
    #10 +
    'User-agent: *'#10 +
    'Disallow: /'#10;
var
  Rules: TRobotRules;
begin
  Rules := ParseRobots(Robots, 'wget');
  Check(Length(Rules) = 4, 'robots: the * group (the empty Disallow adds nothing)');
  Check(RobotsAllow(Rules, '/index.html'), 'robots: allowed');
  Check(not RobotsAllow(Rules, '/cgi-bin/run'), 'robots: a disallowed folder');
  Check(not RobotsAllow(Rules, '/private/secret.html'), 'robots: a disallowed prefix');
  Check(not RobotsAllow(Rules, '/privateer'), 'robots: a prefix, not a folder');
  Check(RobotsAllow(Rules, '/private/open.html'), 'robots: the longer Allow wins');
  Check(not RobotsAllow(Rules, '/docs/paper.pdf'), 'robots: * and $');
  Check(RobotsAllow(Rules, '/docs/paper.pdf?download=1'), 'robots: $ is the end');
  Rules := ParseRobots(ForWget, 'wget');
  Check((Length(Rules) = 1) and not RobotsAllow(Rules, '/only-for-wget/x') and RobotsAllow(Rules, '/x'),
    'robots: the group naming wget, not *');
  Check(RobotsAllow(ParseRobots('', 'wget'), '/anything'), 'robots: an empty file allows everything');
  Check(RobotsAllow(ParseRobots('User-agent: Googlebot'#10'Disallow: /'#10, 'wget'), '/x'),
    'robots: no group for wget or *');
  Check(RobotPatternMatches('/a*b', '/axxb/c') and not RobotPatternMatches('/a*b$', '/axxb/c'),
    'robots: patterns');
  Rules := ParseRobots('User-agent: *'#10'Allow: /x'#10'Disallow: /x'#10, 'wget');
  Check(RobotsAllow(Rules, '/x/y'), 'robots: Allow wins a tie');
end;

procedure TestPatterns;
var
  Accept, Reject: TNameList;
begin
  Accept := ParseNameList('jpg, png,,gif ');
  Check((Length(Accept) = 3) and (Accept[1] = 'png') and (Accept[2] = 'gif'), 'patterns: a list');
  Check(NameListMatches(Accept, 'photo.jpg'), 'patterns: a suffix');
  Check(not NameListMatches(Accept, 'photo.jpeg'), 'patterns: not another suffix');
  Check(not NameListMatches(Accept, 'photo.JPG'), 'patterns: with case');
  Check(WildcardMatches('img*.png', 'img001.png') and not WildcardMatches('img*.png', 'img001.png.txt'),
    'patterns: * matches the whole name');
  Check(WildcardMatches('a?c', 'abc') and not WildcardMatches('a?c', 'ac'), 'patterns: ?');
  Check(WildcardMatches('file[0-9].txt', 'file7.txt') and not WildcardMatches('file[0-9].txt', 'filex.txt'),
    'patterns: a range');
  Check(WildcardMatches('[!a]*', 'bcd') and not WildcardMatches('[!a]*', 'abc'), 'patterns: a negated set');
  Check(WildcardMatches('*', ''), 'patterns: * matches nothing too');
  Reject := ParseNameList('*.tmp,thumb*');
  Check(FileNameAccepted(Accept, Reject, 'photo.png'), 'patterns: accepted');
  Check(not FileNameAccepted(Accept, Reject, 'notes.txt'), 'patterns: not in the accept list');
  Check(not FileNameAccepted(Accept, Reject, 'thumb.png'), 'patterns: in the reject list');
  Check(FileNameAccepted(nil, Reject, 'anything.html'), 'patterns: no accept list takes everything');
  Check(not FileNameAccepted(nil, Reject, 'x.tmp'), 'patterns: but the rejected');
end;

function UrlOf(const Text: string): TUrl;
begin
  ParseUrl(Text, Result);
end;

procedure TestLocalPaths;
var
  Layout: TLocalLayout;
begin
  Layout := Default(TLocalLayout);
  Check(LocalPathFor(UrlOf('http://10.0.2.102/'), Layout) = '10.0.2.102/index.html', 'local path: the root');
  Check(LocalPathFor(UrlOf('http://10.0.2.102/site/a/b.html'), Layout) = '10.0.2.102/site/a/b.html',
    'local path: folders');
  Check(LocalPathFor(UrlOf('http://10.0.2.102/site/'), Layout) = '10.0.2.102/site/index.html',
    'local path: a folder');
  Check(LocalPathFor(UrlOf('http://host:8080/x'), Layout) = 'host:8080/x', 'local path: another port');
  Check(LocalPathFor(UrlOf('https://host/x'), Layout) = 'host/x', 'local path: https''s own port');
  Check(LocalPathFor(UrlOf('http://host/list.cgi?page=2&s=a/b'), Layout) = 'host/list.cgi?page=2&s=a%2Fb',
    'local path: a query stays in the name');
  Check(LocalPathFor(UrlOf('http://host/my%20file.txt'), Layout) = 'host/my file.txt',
    'local path: segments decoded');
  Check(LocalPathFor(UrlOf('http://host/a%2Fb'), Layout) = 'host/a%2Fb', 'local path: no / from an escape');
  Layout.Prefix := 'out';
  Check(LocalPathFor(UrlOf('http://host/x'), Layout) = 'out/host/x', 'local path: -P');
  Layout.NoHostFolder := True;
  Check(LocalPathFor(UrlOf('http://host/a/x'), Layout) = 'out/a/x', 'local path: -nH');
  Layout.NoFolders := True;
  Layout.Prefix := '';
  Check(LocalPathFor(UrlOf('http://host/a/b/x.png'), Layout) = 'x.png', 'local path: -nd');
  Check(RelativeLink('host/a/b.html', 'host/c.png') = '../c.png', 'relative link: up one folder');
  Check(RelativeLink('host/index.html', 'host/sub/page.html') = 'sub/page.html', 'relative link: down');
  Check(RelativeLink('host/a/x.html', 'host/a/y.html') = 'y.html', 'relative link: the same folder');
  Check(RelativeLink('host/a/b/x.html', 'other/y.png') = '../../../other/y.png', 'relative link: another host');
  Check(RelativeLink('x.html', 'y.html') = 'y.html', 'relative link: no folders');
  Check(FolderOf('a/b/c.html') = 'a/b', 'folder of a path');
end;

procedure TestConversion;
const
  Html = '<a href="one.html">1</a><img src="pic.png"><a href="two.html">2</a>';
var
  Links: TFoundLinkArray;
  Replacements: array of string;
begin
  Links := ExtractLinks(Html);
  SetLength(Replacements, Length(Links));
  Replacements[0] := '../one.html';
  Replacements[1] := '';
  Replacements[2] := 'http://example.com/two.html?a=1&b=2';
  Check(ReplaceLinks(Html, Links, Replacements) = '<a href="../one.html">1</a><img src="pic.png">' +
    '<a href="http://example.com/two.html?a=1&amp;b=2">2</a>', 'conversion: links replaced in place');
  Check(EscapeLinkPath('list.cgi?p=2#x 1%') = 'list.cgi%3Fp=2%23x%201%25', 'conversion: a path as a link');
  Check(EscapeAttributeText('a"b''c&d') = 'a&quot;b&#39;c&amp;d', 'conversion: attribute text');
end;

procedure TestRecursion;
begin
  TestLinks;
  TestRobots;
  TestPatterns;
  TestLocalPaths;
  TestConversion;
end;

end.
