import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class AppWebViewScreen extends StatefulWidget {
  final String url;
  final String title;

  const AppWebViewScreen({
    super.key,
    required this.url,
    required this.title,
  });

  @override
  State<AppWebViewScreen> createState() => _AppWebViewScreenState();
}

class _AppWebViewScreenState extends State<AppWebViewScreen> {
  late final WebViewController _controller;
  bool _canGoBack = false;
  bool _canGoForward = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _progress = 0.05),
          onProgress: (p) => setState(() => _progress = p / 100),
          onPageFinished: (_) async {
            await _refreshNavState();
            if (!mounted) return;
            setState(() => _progress = 1);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _refreshNavState() async {
    final back = await _controller.canGoBack();
    final fwd = await _controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = fwd;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Geri',
            onPressed: _canGoBack
                ? () async {
                    await _controller.goBack();
                    await _refreshNavState();
                  }
                : null,
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
          ),
          IconButton(
            tooltip: 'İleri',
            onPressed: _canGoForward
                ? () async {
                    await _controller.goForward();
                    await _refreshNavState();
                  }
                : null,
            icon: const Icon(Icons.arrow_forward_ios_rounded),
          ),
          IconButton(
            tooltip: 'Yenile',
            onPressed: () => _controller.reload(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _progress < 1 ? 1 : 0,
            child: LinearProgressIndicator(
              value: _progress < 1 ? _progress : null,
              minHeight: 2,
              backgroundColor: Colors.transparent,
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
