// SPDX-License-Identifier: GPL-2.0-or-later
/** \file
 *
 * Authors:
 *   Sushant A A <sushant.co19@gmail.com>
 *
 * Copyright (C) 2021 Authors
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#ifndef INK_ACTIONS_FILE_GUI_H
#define INK_ACTIONS_FILE_GUI_H

class InkscapeApplication;
class InkscapeWindow;

void add_actions_file_app(InkscapeApplication *app);
void add_actions_file_window(InkscapeWindow* win);

#endif // INK_ACTIONS_FILE_GUI_H