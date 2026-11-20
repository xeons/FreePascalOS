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
  The URL Standard's parser, serializer, hosts, setters,
  URLSearchParams and origins, on cases written from the standard's
  own examples and its rules (each case says what the standard
  requires; none is downloaded).
}
unit HttpTest.Urls;

{$mode objfpc}
{$H+}

interface

procedure TestUrls;

implementation

uses
  SysUtils,
  TestChecks,
  Url.Accessors,
  Url.DomainNames,
  Url.Origins,
  Url.Parser,
  Url.Punycode,
  Url.Records,
  Url.SearchParams;

{ Expected '' means the input is not a URL. }
procedure CheckParse(const Input, Expected: string);
var
  Url: TUrlRecord;
  Worked: Boolean;
begin
  Worked := ParseUrl(Input, Url);
  if Expected = '' then
    Check(not Worked, 'URL fails: ' + Input)
  else
  begin
    Check(Worked and (SerializeUrl(Url) = Expected), 'URL ' + Input + ' -> ' + Expected);
    if Worked and (SerializeUrl(Url) <> Expected) then
      WriteLn('     got ', SerializeUrl(Url));
  end;
end;

procedure CheckRelative(const Base, Input, Expected: string);
var
  BaseUrl, Url: TUrlRecord;
  Worked: Boolean;
begin
  if not ParseUrl(Base, BaseUrl) then
  begin
    Check(False, 'base parses: ' + Base);
    Exit;
  end;
  Worked := ParseUrl(Input, BaseUrl, Url);
  if Expected = '' then
    Check(not Worked, 'relative fails: ' + Input + ' against ' + Base)
  else
  begin
    Check(Worked and (SerializeUrl(Url) = Expected), 'relative ' + Input + ' against ' + Base + ' -> ' + Expected);
    if Worked and (SerializeUrl(Url) <> Expected) then
      WriteLn('     got ', SerializeUrl(Url));
  end;
end;

procedure TestSpecialUrls;
begin
  CheckParse('https://example.com/', 'https://example.com/');
  CheckParse('HTTPS://EXAMPLE.COM/a/../b', 'https://example.com/b');
  CheckParse('http://example.com:80/', 'http://example.com/');
  CheckParse('https://example.com:443', 'https://example.com/');
  CheckParse('http://example.com:0/', 'http://example.com:0/');
  CheckParse('http://example.com:00080/', 'http://example.com/');
  CheckParse('http://example.com:65535/', 'http://example.com:65535/');
  CheckParse('http://example.com:65536/', '');
  CheckParse('http://example.com:8x/', '');
  CheckParse('https://user:pass@example.com:8080/p?q#f', 'https://user:pass@example.com:8080/p?q#f');
  CheckParse('http://user@@host/', 'http://user%40@host/');
  CheckParse('http://@www.example.com', 'http://www.example.com/');
  CheckParse('http://:@host/', 'http://host/');
  CheckParse('http://a:b@/', '');
  CheckParse('http://us er:p@ss@host/', 'http://us%20er:p%40ss@host/');
  CheckParse('http://example.com/a/./b/../c', 'http://example.com/a/c');
  CheckParse('http://example.com/a/%2e%2E/b', 'http://example.com/b');
  CheckParse('http://example.com/a/.%2E', 'http://example.com/');
  CheckParse('http://example.com/a/..', 'http://example.com/');
  CheckParse('http:\\example.com\a\b', 'http://example.com/a/b');
  CheckParse('http:example.com/', 'http://example.com/');
  CheckParse('http:/example.com/', 'http://example.com/');
  CheckParse('http:///example.com/', 'http://example.com/');
  CheckParse('http://example.com/?q=a b''', 'http://example.com/?q=a%20b%27');
  CheckParse('http://example.com/#a b`<>', 'http://example.com/#a%20b%60%3C%3E');
  CheckParse('http://example.com/{}^`|', 'http://example.com/%7B%7D%5E%60|');
  CheckParse('http://example.com/a"b<c>d', 'http://example.com/a%22b%3Cc%3Ed');
  CheckParse('http://example.com/caf'#$C3#$A9, 'http://example.com/caf%C3%A9');
  CheckParse('  http://example.com/x  '#9#10, 'http://example.com/x');
  CheckParse('ht'#9'tp://exa'#10'mple.com/'#13, 'http://example.com/');
  CheckParse('http://', '');
  CheckParse('http:', '');
  CheckParse('', '');
  CheckParse('example.com', '');
  CheckParse('wss://example.com:443/chat', 'wss://example.com/chat');
  CheckParse('ws://example.com:80/chat', 'ws://example.com/chat');
  CheckParse('ftp://example.com:21/f', 'ftp://example.com/f');
end;

procedure TestHosts;
begin
  CheckParse('http://EXAMPLE.com', 'http://example.com/');
  CheckParse('http://ex%41mple.com', 'http://example.com/');
  CheckParse('http://example.com./', 'http://example.com./');
  CheckParse('http://a b/', '');
  CheckParse('http://exa%00mple.com', '');
  CheckParse('http://exa%25mple.com', '');
  CheckParse('http://a<b/', '');
  CheckParse('http://a^b/', '');
  CheckParse('http://[1:0::]', 'http://[1::]/');
  CheckParse('http://[0:0:0:0:0:0:13.1.68.3]', 'http://[::d01:4403]/');
  CheckParse('http://[::127.0.0.1]', 'http://[::7f00:1]/');
  CheckParse('http://[1:2:3:4:5:6:7:8]/', 'http://[1:2:3:4:5:6:7:8]/');
  CheckParse('http://[1:0:0:2:0:0:0:3]/', 'http://[1:0:0:2::3]/');
  CheckParse('http://[1:0:0:2:0:0:3:4]/', 'http://[1::2:0:0:3:4]/');
  CheckParse('http://[0:1:0:1:0:1:0:1]/', 'http://[0:1:0:1:0:1:0:1]/');
  CheckParse('http://[::]/', 'http://[::]/');
  CheckParse('http://[FEDC:BA98::7654:3210]:8080/', 'http://[fedc:ba98::7654:3210]:8080/');
  CheckParse('http://[1::2::3]/', '');
  CheckParse('http://[1:2:3:4:5:6:7:8:9]/', '');
  CheckParse('http://[1:2:3:4:5:6:7]/', '');
  CheckParse('http://[::1.2.3]/', '');
  CheckParse('http://[::1.2.3.4.5]/', '');
  CheckParse('http://[::01.2.3.4]/', '');
  CheckParse('http://[::256.2.3.4]/', '');
  CheckParse('http://[12345::]/', '');
  CheckParse('http://[::1/', '');
  CheckParse('http://[::1]x/', '');
  CheckParse('http://[fe80::1%25eth0]/', '');
  CheckParse('http://0x7f.1/', 'http://127.0.0.1/');
  CheckParse('http://0177.0.0.1/', 'http://127.0.0.1/');
  CheckParse('http://192.168.257', 'http://192.168.1.1/');
  CheckParse('http://192.168.0.257/', '');
  CheckParse('http://4294967295', 'http://255.255.255.255/');
  CheckParse('http://4294967296', '');
  CheckParse('http://0x100000000/', '');
  CheckParse('http://1.2.3.4.5', '');
  CheckParse('http://1.2.3.4./', 'http://1.2.3.4/');
  CheckParse('http://foo.09', '');
  CheckParse('http://foo.0x', '');
  CheckParse('http://09.com', 'http://09.com/');
  CheckParse('http://0x.0x.0', 'http://0.0.0.0/');
  CheckParse('http://m'#$C3#$BC'nchen.de/', 'http://xn--mnchen-3ya.de/');
  CheckParse('http://B'#$C3#$9C'cher.example/', 'http://xn--bcher-kva.example/');
  CheckParse('http://xn--mnchen-3ya.de/', 'http://xn--mnchen-3ya.de/');
  CheckParse('http://XN--MNCHEN-3YA.de/', 'http://xn--mnchen-3ya.de/');
  CheckParse('http://xn--/', '');
  CheckParse('http://xn--abc-/', '');
  CheckParse('http://'#$EF#$BC#$A5#$EF#$BC#$B8#$EF#$BC#$A1'.com/', 'http://exa.com/');
  CheckParse('http://example'#$E3#$80#$82'com/', 'http://example.com/');
  CheckParse('http://%E2%98%83.net/', 'http://xn--n3h.net/');
  CheckParse('http://a'#$E2#$80#$8D'b/', '');
  CheckParse('http://'#$CE#$94#$CE#$BF'.gr/', 'http://xn--pxaw.gr/');
end;

procedure TestOtherSchemes;
begin
  CheckParse('non-special://test:@test/x', 'non-special://test@test/x');
  CheckParse('non-special://host/a b', 'non-special://host/a%20b');
  CheckParse('sc://'#$C3#$B1, 'sc://%C3%B1');
  CheckParse('sc://a b/', '');
  CheckParse('sc://EXAMPLE/', 'sc://EXAMPLE/');
  CheckParse('sc://x/?q=''', 'sc://x/?q=''');
  CheckParse('sc://x:12/', 'sc://x:12/');
  CheckParse('sc://[::1]/', 'sc://[::1]/');
  CheckParse('sc:///x', 'sc:///x');
  CheckParse('sc:x/y', 'sc:x/y');
  CheckParse('sc:\x', 'sc:\x');
  CheckParse('mailto:user@example.com', 'mailto:user@example.com');
  CheckParse('javascript:alert(1)', 'javascript:alert(1)');
  CheckParse('data:text/plain,hello world', 'data:text/plain,hello world');
  CheckParse('data:,a'#1'b', 'data:,a%01b');
  CheckParse('web+demo:/.//not-a-host/', 'web+demo:/.//not-a-host/');
  CheckParse('web+demo:/..//not-a-host/', 'web+demo:/.//not-a-host/');
  CheckParse('a1+-.b:x', 'a1+-.b:x');
  CheckParse('1a:x', '');
  CheckParse('file:///C:/x', 'file:///C:/x');
  CheckParse('file://localhost/etc', 'file:///etc');
  CheckParse('file:c:\foo\bar', 'file:///c:/foo/bar');
  CheckParse('file:///C|/x', 'file:///C:/x');
  CheckParse('file://server/share', 'file://server/share');
  CheckParse('file:/x', 'file:///x');
  CheckParse('file:', 'file:///');
end;

procedure TestRelative;
const
  Base = 'http://example.org/foo/bar';
begin
  CheckRelative(Base, 'baz', 'http://example.org/foo/baz');
  CheckRelative(Base, '/baz', 'http://example.org/baz');
  CheckRelative(Base, '//other/x', 'http://other/x');
  CheckRelative(Base, '?q', 'http://example.org/foo/bar?q');
  CheckRelative(Base, '#f', 'http://example.org/foo/bar#f');
  CheckRelative(Base, '', 'http://example.org/foo/bar');
  CheckRelative(Base, '../../../x', 'http://example.org/x');
  CheckRelative(Base, 'http:x', 'http://example.org/foo/x');
  CheckRelative(Base, 'https:x', 'https://x/');
  CheckRelative(Base, '\\x\y', 'http://x/y');
  CheckRelative(Base, './', 'http://example.org/foo/');
  CheckRelative(Base, 'a?b#c', 'http://example.org/foo/a?b#c');
  CheckRelative(Base, ' x ', 'http://example.org/foo/x');
  { RFC 3986 section 5.4.1's examples, which the standard keeps. }
  CheckRelative('http://a/b/c/d;p?q', 'g', 'http://a/b/c/g');
  CheckRelative('http://a/b/c/d;p?q', './g', 'http://a/b/c/g');
  CheckRelative('http://a/b/c/d;p?q', 'g/', 'http://a/b/c/g/');
  CheckRelative('http://a/b/c/d;p?q', '/g', 'http://a/g');
  CheckRelative('http://a/b/c/d;p?q', '//g', 'http://g/');
  CheckRelative('http://a/b/c/d;p?q', '?y', 'http://a/b/c/d;p?y');
  CheckRelative('http://a/b/c/d;p?q', 'g?y', 'http://a/b/c/g?y');
  CheckRelative('http://a/b/c/d;p?q', '#s', 'http://a/b/c/d;p?q#s');
  CheckRelative('http://a/b/c/d;p?q', 'g;x?y#s', 'http://a/b/c/g;x?y#s');
  CheckRelative('http://a/b/c/d;p?q', '..', 'http://a/b/');
  CheckRelative('http://a/b/c/d;p?q', '../..', 'http://a/');
  CheckRelative('http://a/b/c/d;p?q', '../../../g', 'http://a/g');
  CheckRelative('http://a/b/c/d;p?q', '/./g', 'http://a/g');
  CheckRelative('http://a/b/c/d;p?q', 'g..', 'http://a/b/c/g..');
  CheckRelative('mailto:a@b', '#x', 'mailto:a@b#x');
  CheckRelative('mailto:a@b', 'x', '');
  CheckRelative('file:///C:/a/b', '/x', 'file:///C:/x');
  CheckRelative('file:///C:/a/b', '..', 'file:///C:/');
  CheckRelative('file:///a/b', 'c', 'file:///a/c');
  CheckRelative('file://host/a/b', '//other/c', 'file://other/c');
  CheckRelative('sc://host/a/b', '../c', 'sc://host/c');
  CheckRelative('sc://host/a/b', '//other', 'sc://other');
  CheckRelative('sc:opaque', '?x', '');
end;

procedure TestAccessors;
var
  Url: TUrlRecord;
begin
  ParseUrl('https://example.com/a?b#c', Url);
  Check((GetProtocol(Url) = 'https:') and (GetHost(Url) = 'example.com') and (GetPathname(Url) = '/a') and
    (GetSearch(Url) = '?b') and (GetHash(Url) = '#c') and (GetPort(Url) = ''), 'getters');
  Check(GetOrigin(Url) = 'https://example.com', 'origin getter');
  SetPort(Url, '8080');
  Check(GetHref(Url) = 'https://example.com:8080/a?b#c', 'port setter');
  SetPort(Url, '443');
  Check(GetHref(Url) = 'https://example.com/a?b#c', 'default port setter');
  SetPort(Url, '8080x');
  Check(GetPort(Url) = '8080', 'port setter stops at a non-digit');
  SetPort(Url, '');
  SetProtocol(Url, 'http');
  Check(GetHref(Url) = 'http://example.com/a?b#c', 'protocol setter');
  SetProtocol(Url, 'mailto');
  Check(GetProtocol(Url) = 'http:', 'protocol setter: special to not special refused');
  SetHostname(Url, 'other.org');
  Check(GetHost(Url) = 'other.org', 'hostname setter');
  SetHostname(Url, 'x.org:99');
  Check(GetHost(Url) = 'other.org', 'hostname setter refuses a port');
  SetHost(Url, 'x.org:81');
  Check(GetHost(Url) = 'x.org:81', 'host setter with a port');
  SetHost(Url, '');
  Check(GetHost(Url) = 'x.org:81', 'host setter: an empty host refused for http');
  SetPathname(Url, '/x y');
  Check(GetPathname(Url) = '/x%20y', 'pathname setter');
  SetSearch(Url, 'q=1 2');
  Check(GetSearch(Url) = '?q=1%202', 'search setter');
  SetSearch(Url, '');
  SetHash(Url, '');
  Check(GetHref(Url) = 'http://x.org:81/x%20y', 'search and hash cleared');
  SetUsername(Url, 'us er');
  SetPassword(Url, 'p:w');
  Check(GetHref(Url) = 'http://us%20er:p%3Aw@x.org:81/x%20y', 'credential setters');
  Check(SetHref(Url, 'https://new.example/') and (GetHost(Url) = 'new.example'), 'href setter');
  Check(not SetHref(Url, 'not a url') and (GetHost(Url) = 'new.example'), 'href setter failure keeps the URL');
  ParseUrl('file:///etc/x', Url);
  SetPort(Url, '81');
  SetUsername(Url, 'u');
  Check(GetHref(Url) = 'file:///etc/x', 'file URLs take no port or user');
  ParseUrl('mailto:a@b ', Url);
  SetHost(Url, 'x');
  Check(GetHref(Url) = 'mailto:a@b', 'an opaque path takes no host');
  ParseUrl('sc://host/p', Url);
  SetHost(Url, '');
  Check(GetHref(Url) = 'sc:///p', 'an empty host is fine for a non-special URL');
end;

procedure TestSearchParams;
var
  Params: TUrlSearchParams;
  Value: string;
  All: TStringArray;
begin
  Params := TUrlSearchParams.Create('?a=1&b=2&a=3');
  try
    All := Params.GetAll('a');
    Check((Length(All) = 2) and (All[0] = '1') and (All[1] = '3'), 'search params: getAll');
    Check(Params.Get('b', Value) and (Value = '2') and not Params.Get('z', Value), 'search params: get');
    Check(Params.Has('a') and Params.Has('a', '3') and not Params.Has('a', '2'), 'search params: has');
    Params.Delete('a');
    Check(Params.ToString = 'b=2', 'search params: delete');
    Params.Append('c', 'x y');
    Check(Params.ToString = 'b=2&c=x+y', 'search params: append, space as +');
    Params.SetValue('b', '9');
    Params.SetValue('d', '');
    Check(Params.ToString = 'b=9&c=x+y&d=', 'search params: set');
    Params.Assign('z=1&a=2&z=0&'#$C3#$A9'=e');
    Params.Sort;
    Check(Params.ToString = 'a=2&z=1&z=0&%C3%A9=e', 'search params: stable sort');
    Params.Assign('a+b=c%20d&&e&=f');
    Check((Params.Count = 3) and (Params[0].Name = 'a b') and (Params[0].Value = 'c d') and
      (Params[1].Name = 'e') and (Params[2].Name = '') and (Params[2].Value = 'f'), 'search params: parsing');
    Params.Assign('');
    Params.Append('~!''()*', '&=+');
    Check(Params.ToString = '%7E%21%27%28%29*=%26%3D%2B', 'search params: the form encode set');
  finally
    Params.Free;
  end;
end;

procedure TestOrigins;
var
  First, Second: TUrlRecord;
begin
  ParseUrl('https://example.com:443/x', First);
  Check(SerializeOrigin(OriginOfUrl(First)) = 'https://example.com', 'origin: default port left out');
  ParseUrl('https://example.com:8443/x', First);
  Check(SerializeOrigin(OriginOfUrl(First)) = 'https://example.com:8443', 'origin: with a port');
  ParseUrl('blob:https://a.com/uuid', First);
  Check(SerializeOrigin(OriginOfUrl(First)) = 'https://a.com', 'origin: of a blob URL');
  ParseUrl('file:///x', First);
  Check(SerializeOrigin(OriginOfUrl(First)) = 'null', 'origin: file is opaque');
  Check(not SameOrigin(OriginOfUrl(First), OriginOfUrl(First)), 'origin: two opaque origins differ');
  ParseUrl('http://example.com/a', First);
  ParseUrl('https://example.com/a', Second);
  Check(not SameOrigin(OriginOfUrl(First), OriginOfUrl(Second)), 'origin: the scheme counts');
  ParseUrl('http://example.com:80/b', Second);
  Check(SameOrigin(OriginOfUrl(First), OriginOfUrl(Second)), 'origin: the same origin');
  ParseUrl('http://127.0.0.1/', First);
  ParseUrl('http://example.com/', Second);
  Check(OriginIsPotentiallyTrustworthy(OriginOfUrl(First)) and
    not OriginIsPotentiallyTrustworthy(OriginOfUrl(Second)), 'origin: loopback is potentially trustworthy');
end;

procedure CheckPunycode(const Unicode, Ascii: string);
var
  Encoded: string;
  Decoded: TCodePointArray;
begin
  Check(PunycodeEncode(Utf8ToCodePoints(Unicode), Encoded) and (Encoded = Ascii), 'punycode encodes ' + Ascii);
  Check(PunycodeDecode(Ascii, Decoded) and (CodePointsToUtf8(Decoded) = Unicode), 'punycode decodes ' + Ascii);
end;

procedure TestPunycode;
var
  Ascii: string;
begin
  CheckPunycode('b'#$C3#$BC'cher', 'bcher-kva');
  CheckPunycode('m'#$C3#$BC'nchen', 'mnchen-3ya');
  CheckPunycode(#$E2#$98#$83, 'n3h');
  CheckPunycode(#$E6#$97#$A5#$E6#$9C#$AC#$E8#$AA#$9E, 'wgv71a119e');
  CheckPunycode(#$D0#$B8#$D1#$81#$D0#$BF#$D1#$8B#$D1#$82#$D0#$B0#$D0#$BD#$D0#$B8#$D0#$B5, '80akhbyknj4f');
  Check(DomainToAscii(#$D0#$98#$D0#$A1#$D0#$9F#$D0#$AB#$D0#$A2#$D0#$90#$D0#$9D#$D0#$98#$D0#$95'.test', Ascii) and
    (Ascii = 'xn--80akhbyknj4f.test'), 'domain to ASCII: Cyrillic capitals lower cased');
  Check(DomainToUnicode('xn--mnchen-3ya.de') = 'm'#$C3#$BC'nchen.de', 'domain to Unicode');
end;

procedure TestUrls;
begin
  TestSpecialUrls;
  TestHosts;
  TestOtherSchemes;
  TestRelative;
  TestAccessors;
  TestSearchParams;
  TestOrigins;
  TestPunycode;
end;

end.
