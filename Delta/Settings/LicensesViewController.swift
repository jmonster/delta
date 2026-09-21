//
//  LicensesViewController.swift
//  Delta
//
//  Created by Riley Testut on 9/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import SwiftUI

extension LicensesViewController
{
    struct ViewRepresentable: UIViewControllerRepresentable
    {
        func makeUIViewController(context: Context) -> LicensesViewController
        {
            let storyboard = UIStoryboard(name: "Settings", bundle: .main)
            let viewController = storyboard.instantiateViewController(withIdentifier: "licenses") as! LicensesViewController
            return viewController
        }

        func updateUIViewController(_ uiViewController: LicensesViewController, context: Context)
        {
            let parentViewController = uiViewController.parent ?? uiViewController
            parentViewController.navigationItem.title = uiViewController.navigationItem.title // Fixes title not appearing in SwiftUI NavigationStack
        }
    }
}

class LicensesViewController: UIViewController
{
    private var _didAppear = false
    
    @IBOutlet private var textView: UITextView!

    override func viewDidLoad()
    {
        super.viewDidLoad()

        // Retain the storyboard's existing license text and formatting.
        let text = NSMutableAttributedString(attributedString: self.textView.attributedText ?? NSAttributedString(string: ""))
        text.append(NSAttributedString(string: "\n\n" + Self.switch2KitNotices, attributes: [
            .font: self.textView.font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: self.textView.textColor ?? UIColor.label
        ]))
        self.textView.attributedText = text
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
        
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
        
        // Fix incorrect initial offset on iPhone SE.
        self.textView.contentOffset.y = 0
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        
        _didAppear = true
    }

    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()
        
        self.textView.textContainerInset.left = self.view.layoutMargins.left
        self.textView.textContainerInset.right = self.view.layoutMargins.right
        self.textView.textContainer.lineFragmentPadding = 0
        
        if !_didAppear
        {
            // Fix incorrect initial offset on iPhone SE.
            self.textView.contentOffset.y = 0
        }
    }
}

private extension LicensesViewController
{
    // Retained from the SDK's CREDITS.md and LICENSES directory. These are
    // third-party notices, not a new license declaration for Switch2Kit itself.
    static let switch2KitNotices = """
    Switch2Kit — Third-party notices
    https://github.com/jmonster/Switch2Kit

    Switch2Kit includes code from Peterksharma/switch2mac.
    Peter Sharma and contributors: application and controller protocol implementation.
    Andrei-Kondrykau: browser integration. vialoh: RetroArch integration.
    ndeadly, Nadeflore, coffincolors, trevlars, darthcloud, and the controller
    research community: protocol research. Sam Lantinga and SDL contributors: SDL.

    Controller reference implementation: trevlars/switch2-controllers-linux

    MIT License

    Copyright (c) 2026 trevlars

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

    SDL notice retained from the upstream SDK. Delta does not use its SDL adapter.
    The SDK's SDL-derived patches are modified, unofficial SDL sources.

    Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

    This software is provided 'as-is', without any express or implied
    warranty.  In no event will the authors be held liable for any damages
    arising from the use of this software.

    Permission is granted to anyone to use this software for any purpose,
    including commercial applications, and to alter it and redistribute it
    freely, subject to the following restrictions:

    1. The origin of this software must not be misrepresented; you must not
       claim that you wrote the original software. If you use this software
       in a product, an acknowledgment in the product documentation would be
       appreciated but is not required.
    2. Altered source versions must be plainly marked as such, and must not be
       misrepresented as being the original software.
    3. This notice may not be removed or altered from any source distribution.
    """
}
