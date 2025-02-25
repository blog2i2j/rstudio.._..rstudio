/*
 * ApplicationView.java
 *
 * Copyright (C) 2022 by Posit Software, PBC
 *
 * Unless you have received this program directly from Posit Software pursuant
 * to the terms of a commercial license agreement with Posit Software, then
 * this program is licensed to you under the terms of version 3 of the
 * GNU Affero General Public License. This program is distributed WITHOUT
 * ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING THOSE OF NON-INFRINGEMENT,
 * MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE. Please refer to the
 * AGPL (http://www.gnu.org/licenses/agpl-3.0.txt) for more details.
 *
 */

package org.rstudio.studio.client.application;

import com.google.gwt.user.client.ui.Widget;
import org.rstudio.core.client.widget.AriaLiveStatusReporter;
import org.rstudio.studio.client.application.events.AriaLiveStatusEvent.Severity;

public interface ApplicationView extends AriaLiveStatusReporter
{
   // set current main view for application
   void showWorkbenchView(Widget widget);
   
   // toolbar
   void showToolbar(boolean showToolbar, boolean announce);
   boolean isToolbarShowing();
   void focusToolbar();
   
   // application exit states
   void showApplicationQuit();
   void showApplicationMultiSessionQuit();
   void showApplicationSuicide(String reason);
   void showApplicationDisconnected();
   void showApplicationOffline();
   void showApplicationUpdateRequired();
   void showMemoryLimitExceeded(String status, boolean abort);
   
   // error messages
   void showSessionAbendWarning();
   void showMemoryLimitWarning(String status, boolean updateOnly, boolean overLimit);
   
   // status or alert message for screen reader users,
   @Override
   void reportStatus(String message, int delayMs, Severity severity);

   // progress
   void showSerializationProgress(String message, 
                                  boolean modal, 
                                  int delayMs, 
                                  int timeoutMs);
   void hideSerializationProgress();
   
   Widget getWidget();

   void showLicenseWarning(boolean severe, String message);
   void showWarning(boolean severe, String message);
   void hideWarning();
}

