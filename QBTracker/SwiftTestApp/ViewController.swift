//
//  ViewController.swift
//  SwiftTestApp
//
//  Created by Dariusz Zajac on 23/08/2017.
//  Copyright © 2017 Qubit. All rights reserved.
//

import UIKit
import QubitSDK
//@testable import QBTracker

class ViewController: UIViewController {

    var timer: Timer?
    @IBOutlet weak var eventsLabel: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        QubitSDK.start(withTrackingId: "miquido", logLevel: .verbose)
        print(QubitSDK.trackingId)
        print(QubitSDK.deviceId)
    }
    
    @IBAction func tapOnEventButton(_ sender: UIButton) {
        for _ in 0...10 {
            QubitSDK.sendEvent(type: "View", data: "{\"type\" : \"tapOnEventButton\", \"number\":2.2}")
        }
    }
    
    @IBAction func tapOnCreateEventButton(_ sender: UIButton) {
        let event = QubitSDK.createEvent(type: "Product", dictionary: ["eventType": "tapOnCreateEventButton", "number": 2.2])
        QubitSDK.sendEvent(event: event)
    }
}
