// Pure Dart Service (Zero Flutter Dependencies)

/// Legacy session metadata, retained for compatibility with existing callers.
/// These presets are NOT used for outbound requests. TargetRequestPolicy owns
/// the fixed application identity; session rotation cannot lift a host denial.
class BrowserFingerprint {
  const BrowserFingerprint({
    required this.id,
    required this.name,
    required this.headers,
  });

  final String id;
  final String name;
  final Map<String, String> headers;

  static const List<BrowserFingerprint> presets = [
    // 1. macOS Chrome 126
    BrowserFingerprint(
      id: 'mac_chrome_126',
      name: 'Chrome 126 on macOS',
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/html, application/xhtml+xml, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Origin': 'https://www.target.com',
        'Referer': 'https://www.target.com/',
        'Sec-Ch-Ua':
            '"Not/A)Brand";v="8", "Chromium";v="126", "Google Chrome";v="126"',
        'Sec-Ch-Ua-Mobile': '?0',
        'Sec-Ch-Ua-Platform': '"macOS"',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
      },
    ),
    // 2. Windows Chrome 125
    BrowserFingerprint(
      id: 'win_chrome_125',
      name: 'Chrome 125 on Windows 11',
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/html, application/xhtml+xml, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Origin': 'https://www.target.com',
        'Referer': 'https://www.target.com/',
        'Sec-Ch-Ua':
            '"Chromium";v="125", "Google Chrome";v="125", "Not:A-Brand";v="99"',
        'Sec-Ch-Ua-Mobile': '?0',
        'Sec-Ch-Ua-Platform': '"Windows"',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
      },
    ),
    // 3. macOS Safari 17
    BrowserFingerprint(
      id: 'mac_safari_17',
      name: 'Safari 17 on macOS',
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Origin': 'https://www.target.com',
        'Referer': 'https://www.target.com/',
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'same-site',
      },
    ),
    // 4. Windows Edge 125
    BrowserFingerprint(
      id: 'win_edge_125',
      name: 'Edge 125 on Windows',
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0',
        'Accept': 'application/json, text/html, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
        'Origin': 'https://www.target.com',
        'Referer': 'https://www.target.com/',
        'Sec-Ch-Ua':
            '"Microsoft Edge";v="125", "Chromium";v="125", "Not:A-Brand";v="99"',
        'Sec-Ch-Ua-Mobile': '?0',
        'Sec-Ch-Ua-Platform': '"Windows"',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
      },
    ),
  ];
}
