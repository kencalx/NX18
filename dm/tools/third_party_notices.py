#!/usr/bin/env python3
"""Write the third-party notices every NX 18 game app carries (dm/ios/Resources/ThirdPartyNotices.txt).

One plain-text file: for each piece of others' work that is compiled into the iPhone, iPad or Mac app, or that the app carries, its name, author, what NX 18 uses it for and its
license text. The texts come from the license files and source-file notices already in the repository, so the file follows them; the two upstream license texts the repository
has only as a one-line notice (deko3d's zlib license, MiniEngine's MIT license) are kept below, as their upstream LICENSE files give them.
dm/ios/tools/build_ipa.sh copies the file into the app (DmIOS.app/dm/ThirdPartyNotices.txt) and dm/mac/pack_app.py into the Mac app (Contents/Resources/dm/ThirdPartyNotices.txt);
the launchers show it as Acknowledgements (dm/ios/Sources/GuideViewer.swift LauncherNoticesSheet, dm/mac/Launcher.swift MacNoticesWindow).

Left out, as nothing of them is in a game app: the build tools' own libraries (LibHac and the .NET runtime in nx_extract and dmsh_xlate, whose notices sit beside those
executables) and NVIDIA FLIP (image checks in dm/verify only).

Usage: third_party_notices.py          write the file
       third_party_notices.py --check  exit 1 when the committed file is not what the sources make (dm/tools/tests/test_third_party_notices.py runs it)
"""
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / 'dm/ios/Resources/ThirdPartyNotices.txt'
RULE = '=' * 78
THIN = '-' * 78

# deko3d's LICENSE (https://github.com/devkitPro/deko3d/blob/master/LICENSE), which dm/gfx/nvn/nvn_tex.c names in one line
DEKO3D_LICENSE = """Copyright (C) 2018-2020 fincs

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any
damages arising from the use of this software.

Permission is granted to anyone to use this software for any
purpose, including commercial applications, and to alter it and
redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you
   must not claim that you wrote the original software. If you use
   this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.
2. Altered source versions must be plainly marked as such, and
   must not be misrepresented as being the original software.
3. This notice may not be removed or altered from any source
   distribution.
"""

# The LICENSE of Microsoft's DirectX-Graphics-Samples (https://github.com/microsoft/DirectX-Graphics-Samples/blob/master/LICENSE), MiniEngine's repository, which
# dm/gfx/msl/cmaa2.metal names in its attribution
MINIENGINE_LICENSE = """The MIT License (MIT)

Copyright (c) 2015 Microsoft

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
"""


def tidy(text):
    """Unix line ends, no trailing spaces, at most one blank line in a row, none at either end"""
    lines = [line.rstrip() for line in text.replace('\r\n', '\n').replace('\r', '\n').split('\n')]
    out = []
    for line in lines:
        if line or (out and out[-1]):
            out.append(line)
    while out and not out[-1]:
        out.pop()
    return '\n'.join(out)


def file(rel):
    """A license file of the repository, whole"""
    return tidy((REPO / rel).read_text(encoding='utf-8'))


def notice(rel, first, last):
    """The notice in a source file's comment: from the line holding first to the next line holding last, both kept, with the comment marks taken off"""
    lines = (REPO / rel).read_text(encoding='utf-8').splitlines()
    start = next((i for i, line in enumerate(lines) if first in line), None)
    if start is None:
        raise SystemExit(f'{rel}: no line with {first!r}; the notice moved, so update dm/tools/third_party_notices.py')
    end = next((i for i in range(start, len(lines)) if last in lines[i]), None)
    if end is None:
        raise SystemExit(f'{rel}: no line with {last!r} after {first!r}')
    return tidy('\n'.join(re.sub(r'^\s*(?://+|#+|/?\*+/?)\s?', '', line) for line in lines[start:end + 1]))


# name, by, license, upstream, what NX 18 uses it for, [license texts]
def components():
    return [
        ('nxnative', 'seedds', 'MIT', 'https://github.com/seedds/nxnative',
         'NX 18 is a fork of nxnative and keeps its license. The app\'s code rewriter, its host (which stands in for the console\'s system) and its NVN-on-Metal '
         'graphics layer are built on nxnative\'s.',
         [file('LICENSE')]),
        ('d2r-mobile', 'jhaizhou', 'MIT', 'https://github.com/jhaizhou-ops/d2r-mobile',
         'nxnative began as a copy of its generic parts: the code rewriter, the host, the NVN-on-Metal layer and the iOS app shell. Some of that code is still in this app.',
         [file('dm/third_party/d2r-mobile/LICENSE')]),
        ('MacNativeGames', 'MacNativeGames contributors', 'MIT', 'https://github.com/ly05010419/MacNativeGames',
         'The GPU widening of 8-bit indices and the in-pass clears of the Metal layer. Its visibility-counter lowering in NX 18\'s shader translator (run on the Mac) shapes the shaders the app carries.',
         [file('dm/third_party/macnativegames/LICENSE')]),
        ('dav1d', 'VideoLAN and dav1d authors', 'BSD-2-Clause', 'https://code.videolan.org/videolan/dav1d',
         'Decodes the games\' AV1 movies.',
         [file('dm/third_party/dav1d/COPYING')]),
        ('libvpx', 'The WebM Project authors', 'BSD-3-Clause, with an additional patent grant', 'https://chromium.googlesource.com/webm/libvpx',
         'Decodes the games\' VP9 movies.',
         [file('dm/third_party/libvpx/LICENSE'), 'Additional IP rights grant (PATENTS):\n\n' + file('dm/third_party/libvpx/PATENTS')]),
        ('stb_vorbis', 'Sean Barrett', 'MIT or public domain', 'https://github.com/nothings/stb',
         'Decodes the Vorbis sound of the games\' WebM movies.',
         [file('dm/third_party/stb_vorbis/LICENSE')]),
        ('nvn.h', 'h1k421', 'MIT', None,
         'The NVN type definitions the graphics layer is built on (dm/gfx/nvn/include/nvn.h).',
         [notice('dm/gfx/nvn/include/nvn.h', 'Copyright (c) 2020 h1k421', 'SOFTWARE.')]),
        ('deko3d', 'fincs', 'zlib', 'https://github.com/devkitPro/deko3d',
         'The texture layout size algorithm (dm/gfx/nvn/nvn_tex.c), ported from deko3d\'s dk_image.cpp. NX 18\'s port is changed from the original.',
         [notice('dm/gfx/nvn/nvn_tex.c', 'The algorithm is ported from deko3d', 'The algorithm is ported from deko3d'), tidy(DEKO3D_LICENSE)]),
        ('CMAA2 (Conservative Morphological Anti-Aliasing 2.3)', 'Intel Corporation', 'Apache-2.0', 'https://github.com/GameTechDev/CMAA2',
         'The edge smoothing of the Anti-aliasing setting. NX 18 ported CMAA2.hlsl to the Metal Shading Language and changed it; the changes are listed at the top of '
         'dm/gfx/msl/cmaa2.metal.',
         [notice('dm/gfx/msl/cmaa2.metal', 'Copyright (c) 2018, Intel Corporation', 'More info:'), file('dm/third_party/cmaa2/LICENSE')]),
        ('MiniEngine pixel packing', 'Microsoft', 'MIT', 'https://github.com/Microsoft/DirectX-Graphics-Samples',
         'The R11G11B10 colour packing inside the CMAA2 port, from MiniEngine\'s PixelPacking_R11G11B10.hlsli, as CMAA2 has it.',
         [notice('dm/gfx/msl/cmaa2.metal', '(R11G11B10 conversion code below taken from Miniengine', 'PixelPacking_R11G11B10.hlsli )'), tidy(MINIENGINE_LICENSE)]),
        ('FidelityFX FSR 1.0', 'Advanced Micro Devices, Inc.', 'MIT', 'https://github.com/GPUOpen-Effects/FidelityFX-FSR',
         'The RCAS sharpening of the Sharpening setting, ported from ffx_fsr1.h to the Metal Shading Language (dm/gfx/msl/present.metal).',
         [notice('dm/gfx/msl/present.metal', 'Copyright (c) 2021 Advanced Micro Devices', 'THE SOFTWARE.')]),
        ('AstralChain-Dynamic-FPS v1.1.1', 'yogesh1239', 'MIT', 'https://github.com/yogesh1239/AstralChain-Dynamic-FPS',
         'In Astral Chain\'s app only: the integer timer and camera helpers of its 60 fps patches (dm/games/01007300020FA000/patches.py), adapted from this project.',
         [notice('dm/games/01007300020FA000/patches.py', 'MIT License', 'SOFTWARE.')]),
        ('Ryujinx shader translator 1.3.2', 'Ryujinx Team and Contributors', 'MIT', 'https://github.com/Ryubing',
         'The app\'s shaders are the game\'s own shaders, translated on the Mac by NX 18\'s dmsh_xlate tool, which is built on Ryujinx\'s shader library. No Ryujinx code runs in '
         'the app. It is listed because the app carries shaders it translated.',
         [file('dm/third_party/ryujinx/LICENSE.txt')]),
        ('SPIRV-Cross', 'The Khronos Group Inc.', 'Apache-2.0', 'https://github.com/KhronosGroup/SPIRV-Cross',
         'Converts the translated shaders to the Metal Shading Language on the Mac. The code it writes, with its helper functions, is compiled into the app\'s shader '
         'libraries.',
         [file('dm/gfx/tools/spirv_cross_bin/LICENSE')]),
        ('Switch Button Icons and Controls', 'Zacksly', 'CC BY 3.0', 'https://zacksly.itch.io',
         'In the iPhone and iPad app: the button glyphs of the controller hints. Button Icons and Controls by Zacksly (CC BY 3.0 Licensed | zacksly.itch.io), modified: '
         'recoloured. The license: https://creativecommons.org/licenses/by/3.0/',
         [file('dm/ios/Resources/ButtonIcons/LICENSE.txt')]),
    ]


def render():
    parts = components()
    out = ['NX 18: Acknowledgements', '',
           'This app is built with the work of the people and projects below. For each one: who made it, what NX 18 uses it for, and its license text.', '',
           'Contents']
    out += [f'  {i}. {name}' for i, (name, *_rest) in enumerate(parts, 1)]
    seen = {}   # a license text given in full once; a later identical one points to it
    for i, (name, by, lic, url, use, texts) in enumerate(parts, 1):
        out += ['', RULE, f'{i}. {name}', f'By {by}{"" if by.endswith(".") else "."} License: {lic}.']
        if url:
            out.append(url)
        out += ['', use, THIN]
        for t in texts:
            out.append('')
            if t in seen:
                out.append(f'The same license text as under {seen[t]} above.')
            else:
                seen.setdefault(t, f'{i}. {name}')
                out.append(t)
    out += ['', RULE, 'Made by dm/tools/third_party_notices.py from the license files in NX 18\'s repository.']
    return '\n'.join(out) + '\n'   # UTF-8 (dav1d's notice and Zacksly's licence have a few non-ASCII characters), which both launchers read


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--check', action='store_true', help='exit 1 when the committed file differs from what the sources make')
    a = ap.parse_args()
    text = render()
    if a.check:
        if not OUT.is_file() or OUT.read_text(encoding='utf-8') != text:
            print(f'{OUT.relative_to(REPO)} is out of date: run python3 dm/tools/third_party_notices.py', file=sys.stderr)
            return 1
        print(f'{OUT.relative_to(REPO)} is up to date')
        return 0
    OUT.write_text(text, encoding='utf-8')
    print(f'wrote {OUT.relative_to(REPO)} ({len(text.splitlines())} lines)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
