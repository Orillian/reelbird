// Outgoing mail. On Tiffin every app gets SMTP_URL (the box's relay, SendGrid for us) and
// EMAIL_FROM (reelbird@shiptiffin.com); the box only lets the project send as its own sender.
// MAIL_CAPTURE=1 keeps messages in memory instead (tests).
import nodemailer from "nodemailer";

export type Mail = { to: string; subject: string; text: string; html: string };

export const captured: Mail[] = [];

const smtpURL = process.env.SMTP_URL?.trim();
const capture = process.env.MAIL_CAPTURE === "1";
const from = process.env.EMAIL_FROM?.trim() || "reelbird@shiptiffin.com";
const transport = !capture && smtpURL ? nodemailer.createTransport(smtpURL) : null;

export const canSendMail = capture || transport !== null;

export async function sendMail(m: Mail) {
  if (capture) {
    captured.push(m);
    return;
  }
  if (!transport) throw new Error("No SMTP_URL: mail can't be sent.");
  await transport.sendMail({ from: `Reelbird <${from}>`, ...m });
}
