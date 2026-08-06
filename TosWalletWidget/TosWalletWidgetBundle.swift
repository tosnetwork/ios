//
//  TosWalletWidgetBundle.swift
//  TosWalletWidget
//
//  Created by Grigory on 25.9.23..
//

import SwiftUI
import WidgetKit

@main
struct TosWalletWidgetBundle: WidgetBundle {
    var body: some Widget {
        RateChartWidget()
        RateWidget()
        BalanceWidget()
    }
}
