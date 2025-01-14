//
//  SetUSerIDViewController.swift
//  OptimoveSDKDev
//
//  Created by Mobile Developer Optimove on 24/09/2017.
//  Copyright © 2017 Optimove. All rights reserved.
//

import UIKit

class SetUserIDViewController: UIViewController
{
    @IBOutlet weak var userIDTextField: UITextField!
    
    @IBAction func pressSetUserID(_ sender: UIButton)
    {
        if let text = userIDTextField.text
        {
            Optimove.sharedInstance.set(userID: text)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Optimove.sharedInstance.setScreenEvent(viewControllersIdetifiers: ["main_screen","login"], url: nil)
    }
}
