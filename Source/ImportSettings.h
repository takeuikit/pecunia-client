/**
 * Copyright (c) 2011, 2012, Pecunia Project. All rights reserved.
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

#import <Cocoa/Cocoa.h>

enum SettingsType {
    SettingsTypeCSV, // Default and fallback for invalid values.
    SettingsTypePDF
};

@interface ImportSettings : NSObject <NSCoding> {
}

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *fields;
@property (nonatomic, copy) NSString *fieldSeparator;
@property (nonatomic, copy) NSString *dateFormat;
@property (nonatomic, copy) NSString *decimalSeparator;
@property (nonatomic, strong) NSNumber *encoding;
@property (nonatomic, strong) NSNumber *ignoreLines;
@property (nonatomic, copy) NSString *accountNumber;
@property (nonatomic, copy) NSString *accountSuffix;
@property (nonatomic, copy) NSString *bankCode;
@property (nonatomic, strong) NSNumber *type; // csv, pdf

@property (assign) BOOL isDirty;
@property (copy) NSString *fileName;

@end

