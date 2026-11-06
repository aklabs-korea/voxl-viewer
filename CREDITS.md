# Credits

## voxl

voxl viewer is an unofficial companion to [voxl](https://github.com/tembo/voxl), the remote
desktop by Tembo. It is not made or endorsed by Tembo. The apps load the web page that your own
voxl serves; no voxl code is copied into this repository.

The app icon, `icon/voxl.ico`, is voxl's favicon. It is used under voxl's MIT license
([source](https://github.com/tembo/voxl/blob/main/LICENSE)):

```
MIT License

Copyright (c) 2026 Tembo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Windows build

The Windows release is self-contained, so it also carries:

- the .NET runtime and Windows Forms, MIT license, .NET Foundation and contributors
  ([license](https://github.com/dotnet/runtime/blob/main/LICENSE.TXT));
- Microsoft's WebView2 SDK, under its own license
  ([package](https://www.nuget.org/packages/Microsoft.Web.WebView2)).
