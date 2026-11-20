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
  wget's cookies on the host: RFC 6265's dates, Set-Cookie parsing,
  domain and path matching, what a request gets back and in which
  order, expiry, and Netscape cookie files both ways.
}
unit WgetTest.Cookies;

{$mode objfpc}
{$H+}

interface

procedure TestCookies;

implementation

uses
  SysUtils,
  TestChecks,
  Http.CookieDates,
  Http.CookieFiles,
  Http.Cookies;

const
  { 2026-01-01 00:00:00 UTC. }
  Now = 1767225600;

procedure TestDates;
var
  Time: Int64;
begin
  Check(DaysFromCivil(1970, 1, 1) = 0, 'cookie dates: the epoch is day 0');
  Check(DaysFromCivil(2000, 3, 1) = 11017, 'cookie dates: 2000-03-01 (a leap year)');
  Check(ParseCookieDate('Sun, 06 Nov 1994 08:49:37 GMT', Time) and (Time = 784111777),
    'cookie dates: RFC 1123');
  Check(ParseCookieDate('Sunday, 06-Nov-94 08:49:37 GMT', Time) and (Time = 784111777),
    'cookie dates: RFC 850, two-digit year');
  Check(ParseCookieDate('Sun Nov  6 08:49:37 1994', Time) and (Time = 784111777), 'cookie dates: asctime');
  Check(ParseCookieDate('Wed, 09 Jun 2021 10:18:14 GMT', Time) and (Time = 1623233894), 'cookie dates: 2021');
  Check(ParseCookieDate('Thu, 01-Jan-2037 00:00:00 GMT', Time) and (Time = 2114380800),
    'cookie dates: after 2036');
  Check(ParseCookieDate('01 Jan 30 00:00:00', Time) and (Time = DaysFromCivil(2030, 1, 1) * 86400),
    'cookie dates: 30 is 2030');
  Check(not ParseCookieDate('Sun, 06 Nov 1994', Time), 'cookie dates: no time is refused');
  Check(not ParseCookieDate('Sun, 32 Nov 1994 08:49:37 GMT', Time), 'cookie dates: day 32 is refused');
  Check(not ParseCookieDate('Sun, 06 Foo 1994 08:49:37 GMT', Time), 'cookie dates: no month is refused');
  Check(not ParseCookieDate('Sun, 06 Nov 1994 25:49:37 GMT', Time), 'cookie dates: hour 25 is refused');
  Check(not ParseCookieDate('06 Nov 1500 08:49:37', Time), 'cookie dates: before 1601 is refused');
end;

procedure TestMatching;
begin
  Check(DomainMatches('example.com', 'example.com'), 'domain match: the same');
  Check(DomainMatches('www.example.com', 'example.com'), 'domain match: a subdomain');
  Check(not DomainMatches('wwwexample.com', 'example.com'), 'domain match: not without a dot');
  Check(not DomainMatches('example.com', 'www.example.com'), 'domain match: not a parent');
  Check(not DomainMatches('1.2.3.4', '2.3.4'), 'domain match: never inside an IP address');
  Check(DomainMatches('1.2.3.4', '1.2.3.4'), 'domain match: an IP address itself');
  Check(PathMatches('/', '/'), 'path match: /');
  Check(PathMatches('/docs/a.html', '/docs'), 'path match: below a path');
  Check(PathMatches('/docs/', '/docs/'), 'path match: the same with a slash');
  Check(PathMatches('/docs/a', '/docs/'), 'path match: below a path with a slash');
  Check(not PathMatches('/docsx', '/docs'), 'path match: not a longer name');
  Check(not PathMatches('/doc', '/docs'), 'path match: not a shorter one');
  Check(DefaultCookiePath('/a/b/c.html') = '/a/b', 'default path: the folder');
  Check(DefaultCookiePath('/a') = '/', 'default path: /');
  Check(DefaultCookiePath('/a/b?x=/y/z') = '/a', 'default path: the query is left out');
  Check(DefaultCookiePath('') = '/', 'default path: empty');
end;

procedure TestParsing;
var
  Cookie: TCookie;
  HasDomain: Boolean;
begin
  Check(ParseSetCookie('SID=31d4d96e407aad42; Path=/; Secure; HttpOnly', Now, Cookie, HasDomain) and
    (Cookie.Name = 'SID') and (Cookie.Value = '31d4d96e407aad42') and (Cookie.Path = '/') and Cookie.Secure and
    Cookie.HttpOnly and not HasDomain and Cookie.HostOnly and not Cookie.Persistent,
    'set-cookie: RFC 6265''s first example');
  Check(ParseSetCookie('lang=en-US; Path=/; Domain=.Example.COM', Now, Cookie, HasDomain) and HasDomain and
    (Cookie.Domain = 'example.com') and not Cookie.HostOnly, 'set-cookie: the domain, its dot and case');
  Check(ParseSetCookie('a=b; Max-Age=3600', Now, Cookie, HasDomain) and Cookie.Persistent and
    (Cookie.ExpiryTime = Now + 3600), 'set-cookie: Max-Age');
  Check(ParseSetCookie('a=b; Max-Age=60; Expires=Wed, 09 Jun 2021 10:18:14 GMT', Now, Cookie, HasDomain) and
    (Cookie.ExpiryTime = Now + 60), 'set-cookie: Max-Age wins over a later Expires');
  Check(ParseSetCookie('a=b; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Max-Age=60', Now, Cookie, HasDomain) and
    (Cookie.ExpiryTime = Now + 60), 'set-cookie: Max-Age wins over an earlier Expires');
  Check(ParseSetCookie('a=b; Max-Age=0', Now, Cookie, HasDomain) and Cookie.Persistent and
    (Cookie.ExpiryTime < Now), 'set-cookie: Max-Age 0 has expired');
  Check(ParseSetCookie('a=b; Max-Age=soon', Now, Cookie, HasDomain) and not Cookie.Persistent,
    'set-cookie: a bad Max-Age is ignored');
  Check(ParseSetCookie('  name = value with spaces  ; path=/x', Now, Cookie, HasDomain) and
    (Cookie.Name = 'name') and (Cookie.Value = 'value with spaces') and (Cookie.Path = '/x'),
    'set-cookie: blanks around the name and value');
  Check(ParseSetCookie('a=b; path=relative', Now, Cookie, HasDomain) and (Cookie.Path = ''),
    'set-cookie: a path not starting with / is ignored');
  Check(ParseSetCookie('empty=', Now, Cookie, HasDomain) and (Cookie.Value = ''), 'set-cookie: an empty value');
  Check(ParseSetCookie('a=b=c', Now, Cookie, HasDomain) and (Cookie.Value = 'b=c'), 'set-cookie: = in the value');
  { RFC 6265bis: a pair without "=" (or with nothing before it) is a
    cookie with an empty name; only an empty name and value is refused. }
  Check(ParseSetCookie('novalue', Now, Cookie, HasDomain) and (Cookie.Name = '') and (Cookie.Value = 'novalue'),
    'set-cookie: no = makes a nameless cookie');
  Check(ParseSetCookie('=value', Now, Cookie, HasDomain) and (Cookie.Name = '') and (Cookie.Value = 'value'),
    'set-cookie: an empty name is a nameless cookie');
  Check(not ParseSetCookie('=', Now, Cookie, HasDomain), 'set-cookie: no name and no value is refused');
  Check(ParseSetCookie('a=b; unknown=1; Domain=', Now, Cookie, HasDomain) and not HasDomain,
    'set-cookie: unknown attributes and an empty domain are ignored');
end;

procedure TestJar;
var
  Jar: TCookieJar;
begin
  Jar := TCookieJar.Create;
  try
    Check(Jar.ReceiveSetCookie('SID=1; Path=/', 'www.example.com', '/login', Now), 'jar: a host-only cookie');
    Check(Jar.ReceiveSetCookie('lang=en; Domain=example.com; Path=/', 'www.example.com', '/', Now),
      'jar: a domain cookie');
    Check(Jar.ReceiveSetCookie('deep=1; Path=/docs', 'www.example.com', '/', Now), 'jar: a deeper path');
    Check(Jar.ReceiveSetCookie('dir=1', 'www.example.com', '/shop/cart.html', Now), 'jar: the default path');
    Check(Jar.ReceiveSetCookie('safe=1; Secure', 'www.example.com', '/', Now), 'jar: a secure cookie');
    Check(not Jar.ReceiveSetCookie('evil=1; Domain=other.com', 'www.example.com', '/', Now),
      'jar: another domain is refused');
    Check(not Jar.ReceiveSetCookie('tld=1; Domain=com', 'www.example.com', '/', Now),
      'jar: a top-level domain is refused');
    Check(not Jar.ReceiveSetCookie('sub=1; Domain=www.example.com', 'example.com', '/', Now),
      'jar: a subdomain of the host is refused');
    Check(Jar.Count = 5, 'jar: five cookies kept');

    Check(Jar.CookieHeaderFor('www.example.com', '/', False, Now) = 'SID=1; lang=en',
      'jar: the cookies for /');
    Check(Jar.CookieHeaderFor('www.example.com', '/', True, Now) = 'SID=1; lang=en; safe=1',
      'jar: secure cookies over https only');
    Check(Jar.CookieHeaderFor('www.example.com', '/docs/x.html?q=1', False, Now) = 'deep=1; SID=1; lang=en',
      'jar: longer paths first');
    Check(Jar.CookieHeaderFor('www.example.com', '/shop/item', False, Now) = 'dir=1; SID=1; lang=en',
      'jar: the default path cookie in its folder');
    Check(Jar.CookieHeaderFor('example.com', '/', False, Now) = 'lang=en',
      'jar: the domain cookie on the domain itself, not the host-only one');
    Check(Jar.CookieHeaderFor('img.example.com', '/', False, Now) = 'lang=en', 'jar: the domain cookie elsewhere');
    Check(Jar.CookieHeaderFor('example.org', '/', False, Now) = '', 'jar: nothing for another site');

    Check(Jar.ReceiveSetCookie('SID=2; Path=/', 'www.example.com', '/', Now), 'jar: a cookie replaced');
    Check((Jar.Count = 5) and (Jar.CookieHeaderFor('www.example.com', '/', False, Now) = 'SID=2; lang=en'),
      'jar: the replacement keeps its place');
    Check(Jar.ReceiveSetCookie('SID=gone; Path=/; Max-Age=0', 'www.example.com', '/', Now),
      'jar: an expired cookie removes one');
    Check((Jar.Count = 4) and (Jar.CookieHeaderFor('www.example.com', '/', False, Now) = 'lang=en'),
      'jar: and is not kept');
    Check(Jar.ReceiveSetCookie('short=1; Max-Age=10', 'www.example.com', '/', Now), 'jar: a short-lived cookie');
    Check(Pos('short=1', Jar.CookieHeaderFor('www.example.com', '/', False, Now + 5)) > 0, 'jar: alive at 5 s');
    Check(Pos('short=1', Jar.CookieHeaderFor('www.example.com', '/', False, Now + 11)) = 0, 'jar: gone at 11 s');
    Jar.RemoveExpired(Now + 11);
    Check(Jar.Count = 4, 'jar: expired cookies removed');
    Check(Jar.ReceiveSetCookie('ip=1', '10.0.2.102', '/', Now) and
      (Jar.CookieHeaderFor('10.0.2.102', '/', False, Now) = 'ip=1'), 'jar: a cookie of an IP address');
  finally
    Jar.Free;
  end;
end;

procedure TestFiles;
const
  FileText = '# Netscape HTTP Cookie File'#10 +
    '.example.com'#9'TRUE'#9'/'#9'FALSE'#9'2000000000'#9'lang'#9'en'#10 +
    'www.example.com'#9'FALSE'#9'/docs'#9'TRUE'#9'0'#9'session'#9'abc'#13#10 +
    '#HttpOnly_www.example.com'#9'FALSE'#9'/'#9'FALSE'#9'2000000000'#9'hidden'#9'h'#10 +
    'old.example.com'#9'FALSE'#9'/'#9'FALSE'#9'1000'#9'expired'#9'x'#10 +
    'bad line'#10 +
    'www.example.com'#9'FALSE'#9'/'#9'FALSE'#9'2000000000'#9'empty'#9#10;
var
  Jar: TCookieJar;
  Saved: string;
  Again: TCookieJar;
begin
  Jar := TCookieJar.Create;
  Again := TCookieJar.Create;
  try
    Check(LoadCookieText(Jar, FileText, Now) = 4, 'cookie file: four cookies read');
    Check(Jar.CookieHeaderFor('www.example.com', '/docs/', True, Now) = 'session=abc; lang=en; hidden=h; empty=',
      'cookie file: what was read is sent');
    Check(Jar.CookieHeaderFor('www.example.com', '/docs/', False, Now) = 'lang=en; hidden=h; empty=',
      'cookie file: TRUE in the secure column');
    Check(Jar.CookieHeaderFor('a.example.com', '/', False, Now) = 'lang=en', 'cookie file: subdomains');
    Saved := SaveCookieText(Jar, False, Now);
    Check(Pos('.example.com'#9'TRUE'#9'/'#9'FALSE'#9'2000000000'#9'lang'#9'en'#10, Saved) > 0,
      'cookie file: a domain cookie written');
    Check(Pos('#HttpOnly_www.example.com'#9'FALSE'#9'/'#9'FALSE'#9'2000000000'#9'hidden'#9'h'#10, Saved) > 0,
      'cookie file: an HttpOnly cookie written');
    Check(Pos('session', Saved) = 0, 'cookie file: no session cookie without --keep-session-cookies');
    Saved := SaveCookieText(Jar, True, Now);
    Check(Pos('www.example.com'#9'FALSE'#9'/docs'#9'TRUE'#9'0'#9'session'#9'abc'#10, Saved) > 0,
      'cookie file: a session cookie written with an expiry of 0');
    Check(LoadCookieText(Again, Saved, Now) = 4, 'cookie file: what was written reads back');
    Check(Again.CookieHeaderFor('www.example.com', '/docs/', True, Now) =
      Jar.CookieHeaderFor('www.example.com', '/docs/', True, Now), 'cookie file: and sends the same');
    Check(Copy(SaveCookieText(Jar, False, Now + 2000000000), 1, 1) = '#', 'cookie file: a header first');
    Check(Pos('lang', SaveCookieText(Jar, False, 2000000001)) = 0, 'cookie file: expired cookies not written');
  finally
    Again.Free;
    Jar.Free;
  end;
end;

procedure TestCookies;
begin
  TestDates;
  TestMatching;
  TestParsing;
  TestJar;
  TestFiles;
end;

end.
