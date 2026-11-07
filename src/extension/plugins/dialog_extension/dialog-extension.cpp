// SPDX-License-Identifier: GPL-2.0-or-later
#include <gmodule.h>

#include "extension/effect.h"
#include "extension/implementation/implementation.h"
#include "inkscape-version.h"

namespace {

class DialogExtensionImpl : public Inkscape::Extension::Implementation::Implementation
{
public:
    bool custom_gui() const override { return true; }

    void effect(Inkscape::Extension::Effect *effect, Inkscape::Extension::ExecutionEnv *, SPDesktop *,
                Inkscape::Extension::Implementation::ImplementationDocumentCache *) override
    {
        static_cast<Inkscape::Extension::Extension *>(effect)->prefs();
    }
    void effect(Inkscape::Extension::Effect *effect, Inkscape::Extension::ExecutionEnv *, SPDocument *document) override
    {
        static_cast<Inkscape::Extension::Extension *>(effect)->prefs();
    }
};

} // namespace

extern "C" G_MODULE_EXPORT Inkscape::Extension::Implementation::Implementation *GetImplementation()
{
    return new DialogExtensionImpl();
}

extern "C" G_MODULE_EXPORT const gchar *GetInkscapeVersion()
{
    return Inkscape::version_string;
}
