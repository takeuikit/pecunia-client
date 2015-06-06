/**
 * Copyright (c) 2015, Pecunia Project. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; version 2 of the
 * License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
 * 02110-1301  USA
 */

// Contains the implementation needed to run JS code.

import Foundation
import WebKit
import AppKit

@objc protocol JSLogger : JSExport {
    func logError(message: String) -> Void;
    func logWarning(message: String) -> Void;
    func logInfo(message: String) -> Void;
    func logDebug(message: String) -> Void;
    func logVerbose(message: String) -> Void;
}

class WebClient: WebView, WebViewJSExport {
    private var redirecting: Bool = false;

    var URL: String {
        get {
            return mainFrameURL;
        }
        set {
            redirecting = false;
            if let url = NSURL(string: newValue) {
                mainFrame.loadRequest(NSURLRequest(URL: url));
            }
        }
    }

    var callback: JSValue = JSValue();
    var completion: ([BankQueryResult]) -> Void = {([BankQueryResult]) -> Void in }; // Block to call on results arrival.

    func resultsArrived(results: JSValue) -> Void {
        if let entries = results.toArray() as? [[String: AnyObject]] {
            var queryResults: [BankQueryResult] = [];

            for entry in entries {
                var queryResult = BankQueryResult();

                if let type = entry["isCreditCard"] as? String {
                    queryResult.type = (type == "yes") ? .CreditCard : .BankStatement;
                }

                if let lastSettleDate = entry["lastSettleDate"] as? NSDate {
                    queryResult.lastSettleDate = lastSettleDate;
                }

                if let account = entry["account"] as? String, let bankCode = entry["bankCode"] as? String {
                    queryResult.account = BankAccount.findAccountWithNumber(account, bankCode: bankCode);
                    if queryResult.type == .CreditCard {
                        queryResult.ccNumber = account;
                    }
                }

                // Balance string might contain a currency code (3 letters).
                let balance = (entry["balance"] as! String);
                queryResult.balance = NSDecimalNumber(string: balance, locale: NSLocale.currentLocale()); // Returns the value up to the currency code (if any).

                let statements = entry["statements"] as! [[String: AnyObject]];
                for jsonStatement in statements {
                    var statement: BankStatement = BankStatement.createTemporary();
                    if let final = jsonStatement["final"] as? String {
                        statement.isPreliminary = final != "true";
                    }

                    if let date = jsonStatement["valutaDate"] as? NSDate {
                        statement.valutaDate = date.dateByAddingTimeInterval(12 * 3600); // Add 12hrs so we start at noon.
                    }

                    if let date = jsonStatement["date"] as? NSDate {
                        statement.date = date.dateByAddingTimeInterval(12 * 3600);
                    }

                    if let purpose = jsonStatement["transactionText"] as? String {
                        statement.purpose = purpose;
                    }

                    // Note: using the current locale to convert the values limits us to what the user
                    //       has set in his/her system. The plugins probably know how a floating point
                    //       number is set for the website they work with, but we will lose precision
                    //       if we let JS convert the string to a number.
                    if let value = jsonStatement["value"] as? String  where count(value) > 0 {
                        // For some unknown reasons the Swift doesn't allow to assign a value to the .value property.
                        // Using dictionary access instead for the time being until this is resolved.
                        let number = NSDecimalNumber(string: value, locale: NSLocale.currentLocale());
                        statement.setValue(number, forKey: "value");
                    }

                    if let value = jsonStatement["originalValue"] as? String where count(value) > 0 {
                        statement.origValue = NSDecimalNumber(string: value, locale: NSLocale.currentLocale());
                    }
                    queryResult.statements.append(statement);
                }
                queryResults.append(queryResult);
            }
            completion(queryResults);
        }
    }
}

class PluginContext : NSObject {
    private let webClient: WebClient;
    private let workContext: JSContext; // The context on which we run the script.
                                        // WebView's context is recreated on loading a new page,
                                        // stopping so any running JS code.
    private var jsLogger: JSLogger;
    private var debugScript: String = "";

    init?(pluginFile: String, logger: JSLogger, hostWindow: NSWindow?) {
        jsLogger = logger;
        webClient = WebClient();

        workContext = JSContext();
        super.init();

        prepareContext();

        if let script = String(contentsOfFile: pluginFile, encoding: NSUTF8StringEncoding, error: nil) {
            let parseResult = workContext.evaluateScript(script);
            if parseResult.toString() != "true" {
                logger.logError("Script loaded but did not return \"true\"");
                return nil;
            }
        } else {
            logger.logError("Failed to parse script");
            return nil;
        }

        webClient.frameLoadDelegate = self;
        webClient.hostWindow = hostWindow;
        if hostWindow != nil {
            hostWindow!.contentView = webClient;
        }
    }

    init?(script: String, logger: JSLogger, hostWindow: NSWindow) {
        jsLogger = logger;
        webClient = WebClient();

        workContext = JSContext();
        super.init();

        prepareContext();

        let parseResult = workContext.evaluateScript(script);
        if parseResult.toString() != "true" {
            return nil;
        }

        webClient.frameLoadDelegate = self;
        webClient.hostWindow = hostWindow;
        hostWindow.contentView = webClient;
    }

    // MARK: - Setup

    private func prepareContext() {
        workContext.setObject(false, forKeyedSubscript: "JSError");
        workContext.exceptionHandler = { workContext, exception in
            self.jsLogger.logError(exception.toString());
            workContext.setObject(true, forKeyedSubscript: "JSError");
        }

        workContext.setObject(jsLogger.self, forKeyedSubscript: "logger");
        webClient.mainFrame.javaScriptContext.setObject(jsLogger.self, forKeyedSubscript: "logger");

        // Export Webkit to the work context, so that plugins can use it to work with data/the DOM
        // from the web client.
        workContext.setObject(DOMNodeList.self, forKeyedSubscript: "DOMNodeList");
        workContext.setObject(DOMCSSStyleDeclaration.self, forKeyedSubscript: "DOMCSSStyleDeclaration");
        workContext.setObject(DOMCSSRuleList.self, forKeyedSubscript: "DOMCSSRuleList");
        workContext.setObject(DOMNamedNodeMap.self, forKeyedSubscript: "DOMNamedNodeMap");
        workContext.setObject(DOMNode.self, forKeyedSubscript: "DOMNode");
        workContext.setObject(DOMAttr.self, forKeyedSubscript: "DOMAttr");
        workContext.setObject(DOMElement.self, forKeyedSubscript: "DOMElement");
        workContext.setObject(DOMHTMLCollection.self, forKeyedSubscript: "DOMHTMLCollection");
        workContext.setObject(DOMHTMLElement.self, forKeyedSubscript: "DOMHTMLElement");
        workContext.setObject(DOMDocumentType.self, forKeyedSubscript: "DOMDocumentType");
        workContext.setObject(DOMHTMLFormElement.self, forKeyedSubscript: "DOMHTMLFormElement");
        workContext.setObject(DOMHTMLInputElement.self, forKeyedSubscript: "DOMHTMLInputElement");
        workContext.setObject(DOMHTMLButtonElement.self, forKeyedSubscript: "DOMHTMLButtonElement");
        workContext.setObject(DOMHTMLAnchorElement.self, forKeyedSubscript: "DOMHTMLAnchorElement");
        workContext.setObject(DOMHTMLOptionElement.self, forKeyedSubscript: "DOMHTMLOptionElement");
        workContext.setObject(DOMHTMLOptionsCollection.self, forKeyedSubscript: "DOMHTMLOptionsCollection");
        workContext.setObject(DOMHTMLSelectElement.self, forKeyedSubscript: "DOMHTMLSelectElement");
        workContext.setObject(DOMImplementation.self, forKeyedSubscript: "DOMImplementation");
        workContext.setObject(DOMStyleSheetList.self, forKeyedSubscript: "DOMStyleSheetList");
        workContext.setObject(DOMDocumentFragment.self, forKeyedSubscript: "DOMDocumentFragment");
        workContext.setObject(DOMCharacterData.self, forKeyedSubscript: "DOMCharacterData");
        workContext.setObject(DOMText.self, forKeyedSubscript: "DOMText");
        workContext.setObject(DOMComment.self, forKeyedSubscript: "DOMComment");
        workContext.setObject(DOMCDATASection.self, forKeyedSubscript: "DOMCDATASection");
        workContext.setObject(DOMProcessingInstruction.self, forKeyedSubscript: "DOMProcessingInstruction");
        workContext.setObject(DOMEntityReference.self, forKeyedSubscript: "DOMEntityReference");
        workContext.setObject(DOMDocument.self, forKeyedSubscript: "DOMDocument");
        workContext.setObject(WebFrame.self, forKeyedSubscript: "WebFrame");
        workContext.setObject(webClient.self, forKeyedSubscript: "webClient");
    }

    // MARK: - Plugin Logic

    // Allows to add any additional script to the plugin context.
    func addScript(script: String) {
        workContext.evaluateScript(script);
    }

    // Like addScript but for both contexts. Applied on the webclient context each time
    // it is recreated.
    func addDebugScript(script: String) {
        debugScript = script;
        workContext.evaluateScript(script);
    }

    func pluginInfo() -> (name: String, author: String, description: String, homePage: String, license: String, version: String) {

        return (
            name: workContext.objectForKeyedSubscript("name").toString(),
            author: workContext.objectForKeyedSubscript("author").toString(),
            description: workContext.objectForKeyedSubscript("description").toString(),
            homePage: workContext.objectForKeyedSubscript("homePage").toString(),
            license: workContext.objectForKeyedSubscript("license").toString(),
            version: workContext.objectForKeyedSubscript("version").toString()
        );
    }

    // Calls the getStatements() plugin function and translates results from JSON to a BankQueryResult list.
    func getStatements(userId: String, bankCode: String, password: String, fromDate: NSDate, toDate: NSDate,
        accounts: [String], completion: ([BankQueryResult]) -> Void) -> Void {
            let scriptFunction: JSValue = workContext.objectForKeyedSubscript("getStatements");
            let pluginId = workContext.objectForKeyedSubscript("name").toString();
            if scriptFunction.isUndefined() {
                jsLogger.logError("Error: getStatements() not found in plugin " + pluginId);
                return;
            }

            webClient.completion = completion;
            if !(scriptFunction.callWithArguments([userId, bankCode, password, fromDate, toDate, accounts]) != nil) {
                jsLogger.logError("getStatements() didn't properly start for plugin " + pluginId);
            }
    }

    func getFunction(name: String) -> JSValue {
        return workContext.objectForKeyedSubscript(name);
    }

    // Returns the outer body HTML text.
    func getCurrentHTML() -> String {
        return webClient.mainFrame.document.body.outerHTML;
    }

    
    // MARK: - webView delegate methods.

    internal override func webView(sender: WebView!, didStartProvisionalLoadForFrame frame: WebFrame!) {
        jsLogger.logVerbose("(*) Start loading");
        webClient.redirecting = false; // Gets set when we get redirected while processing the provisional frame.
    }

    internal override func webView(sender: WebView!, didReceiveServerRedirectForProvisionalLoadForFrame frame: WebFrame!) {
        jsLogger.logVerbose("(*) Received server redirect for frame");
    }

    internal override func webView(sender: WebView!, didCommitLoadForFrame frame: WebFrame!) {
        jsLogger.logVerbose("(*) Committed load for frame");
    }

    internal override func webView(sender: WebView!, willPerformClientRedirectToURL URL: NSURL!,
        delay seconds: NSTimeInterval, fireDate date: NSDate!, forFrame frame: WebFrame!) {
            jsLogger.logVerbose("(*) Performing client redirection...");
            webClient.redirecting = true;
    }

    internal override func webView(sender: WebView!, didCreateJavaScriptContext context: JSContext, forFrame: WebFrame!) {
        jsLogger.logVerbose("(*) JS create");
    }

    internal override func webView(sender: WebView!, didFinishLoadForFrame frame: WebFrame!) {
        jsLogger.logVerbose("(*) Finished loading frame from URL: " + frame.dataSource!.response.URL!.absoluteString!);
        if webClient.redirecting {
            webClient.redirecting = false;
            return;
        }

        if !webClient.callback.isUndefined() && !webClient.callback.isNull() {
            jsLogger.logVerbose("(*) Calling callback...");
            webClient.callback.callWithArguments([false]);
        }
    }

    internal override func webView(sender: WebView!, willCloseFrame frame: WebFrame!) {
        jsLogger.logVerbose("(*) Closing frame...");
    }

    internal override func webView(sender: WebView!, didFailLoadWithError error: NSError!, forFrame frame: WebFrame!) {
        jsLogger.logError("(*) Navigating to webpage failed with error: \(error.localizedDescription)")
    }
}
