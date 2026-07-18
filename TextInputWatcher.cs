using System.Windows.Automation;

/// <summary>
/// Detects whether the currently focused UI element anywhere on the desktop
/// is something you'd expect to type into (text box, search field, combo
/// box, etc.), using UI Automation instead of the raw Win32 caret API.
/// This works across classic Win32 apps (Notepad), UWP/XAML apps (File
/// Explorer search, Settings), browsers, and Electron apps -- none of which
/// reliably expose a native Win32 caret handle.
/// </summary>
public static class TextInputWatcher
{
    public static bool IsTextInputActive()
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element == null) return false;

            var controlType = element.Current.ControlType;
            if (controlType == ControlType.Edit ||
                controlType == ControlType.Document ||
                controlType == ControlType.ComboBox ||
                controlType == ControlType.Spinner)
            {
                return true;
            }

            // Catches custom-drawn text controls (common in browsers/Electron)
            // that don't report an Edit/Document ControlType but still expose
            // an editable value.
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePatternObj))
            {
                return !((ValuePattern)valuePatternObj).Current.IsReadOnly;
            }

            if (element.TryGetCurrentPattern(TextPattern.Pattern, out _))
            {
                return true;
            }

            return false;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[CARET] IsTextInputActive threw: {ex.GetType().Name}: {ex.Message}");
            return false;
        }
    }
}