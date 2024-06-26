import log from "@/next/log";
import InfoOutlinedIcon from "@mui/icons-material/InfoOutlined";
import {
    Dialog,
    DialogActions,
    DialogContent,
    DialogTitle,
    IconButton,
    InputAdornment,
    Link,
    TextField,
    useMediaQuery,
    type ModalProps,
} from "@mui/material";
import { useFormik } from "formik";
import { t } from "i18next";
import React from "react";
import { z } from "zod";
import { FocusVisibleButton } from "./FocusVisibleButton";
import { SlideTransition } from "./SlideTransition";

interface DevSettingsProps {
    /** If `true`, then the dialog is shown. */
    open: boolean;
    /** Called when the dialog wants to be closed. */
    onClose: () => void;
}

/**
 * A dialog allowing the user to set the API origin that the app connects to.
 * See: [Note: Configuring custom server].
 */
export const DevSettings: React.FC<DevSettingsProps> = ({ open, onClose }) => {
    const fullScreen = useMediaQuery("(max-width: 428px)");

    const handleDialogClose: ModalProps["onClose"] = (_, reason: string) => {
        // Don't close on backdrop clicks.
        if (reason != "backdropClick") onClose();
    };

    const form = useFormik({
        initialValues: {
            apiOrigin: localStorage.getItem("apiOrigin") ?? "",
        },
        validate: ({ apiOrigin }) => {
            try {
                apiOrigin && new URL(apiOrigin);
            } catch {
                return { apiOrigin: "Invalid endpoint" };
            }
            return {};
        },
        onSubmit: async (values, { setSubmitting, setErrors }) => {
            try {
                await updateAPIOrigin(values.apiOrigin);
            } catch (e) {
                // The person using this functionality is likely a developer and
                // might be helped more by the original error instead of a
                // friendlier but less specific message.
                setErrors({
                    apiOrigin: e instanceof Error ? e.message : String(e),
                });
                return;
            }

            setSubmitting(false);
            onClose();
        },
    });

    // Show validation errors only after the form has been submitted once (the
    // touched state of apiOrigin gets set too early, perhaps because of the
    // autoFocus).
    const hasError =
        form.submitCount > 0 &&
        form.touched.apiOrigin &&
        !!form.errors.apiOrigin;

    return (
        <Dialog
            {...{ open, fullScreen }}
            onClose={handleDialogClose}
            TransitionComponent={SlideTransition}
            maxWidth="xs"
        >
            <form onSubmit={form.handleSubmit}>
                <DialogTitle>{t("developer_settings")}</DialogTitle>
                <DialogContent
                    sx={{
                        "&&": {
                            paddingBlock: "8px",
                        },
                    }}
                >
                    <TextField
                        fullWidth
                        autoFocus
                        id="apiOrigin"
                        name="apiOrigin"
                        label={t("server_endpoint")}
                        placeholder="http://localhost:8080"
                        value={form.values.apiOrigin}
                        onChange={form.handleChange}
                        onBlur={form.handleBlur}
                        error={hasError}
                        helperText={
                            hasError
                                ? form.errors.apiOrigin
                                : " " /* always show an empty string to prevent a layout shift */
                        }
                        InputProps={{
                            endAdornment: (
                                <InputAdornment position="end">
                                    <Link
                                        href="https://help.ente.io/self-hosting/guides/custom-server/"
                                        target="_blank"
                                        rel="noopener"
                                    >
                                        <IconButton
                                            aria-label={t("more_information")}
                                            color="secondary"
                                            edge="end"
                                        >
                                            <InfoOutlinedIcon />
                                        </IconButton>
                                    </Link>
                                </InputAdornment>
                            ),
                        }}
                    />
                </DialogContent>
                <DialogActions>
                    <FocusVisibleButton
                        type="submit"
                        color="accent"
                        fullWidth
                        disabled={form.isSubmitting}
                        disableRipple
                    >
                        {t("save")}
                    </FocusVisibleButton>
                    <FocusVisibleButton
                        onClick={onClose}
                        color="secondary"
                        fullWidth
                        disableRipple
                    >
                        {t("CANCEL")}
                    </FocusVisibleButton>
                </DialogActions>
            </form>
        </Dialog>
    );
};

/**
 * Save {@link origin} to local storage after verifying it with a ping.
 *
 * The given {@link origin} will be verifying by making an API call to the
 * `/ping` endpoint. If that succeeds, then it will be saved to local storage,
 * and all subsequent API calls will use it as the {@link apiOrigin}.
 *
 * See: [Note: Configuring custom server].
 *
 * @param origin The new API origin to use. Pass an empty string to clear the
 * previously saved API origin (if any).
 */
const updateAPIOrigin = async (origin: string) => {
    if (!origin) {
        localStorage.removeItem("apiOrigin");
        return;
    }

    const url = `${origin}/ping`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Failed to fetch ${url}: HTTP ${res.status}`);
    try {
        PingResponse.parse(await res.json());
    } catch (e) {
        log.error("Invalid response", e);
        throw new Error("Invalid response");
    }

    localStorage.setItem("apiOrigin", origin);
};

const PingResponse = z.object({
    message: z.enum(["pong"]),
});
