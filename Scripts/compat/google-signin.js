// Types an address into Google's sign-in form and presses Next, for the
// guide's "Google sign-in" measurement:
//   Compat -url https://accounts.google.com/ -script Scripts/compat/google-signin.js
// Enters no password. Run it a handful of times, not in a loop: Google
// asks for a CAPTCHA after a few tries from one address.
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  let field;
  for (let i = 0; i < 40 && !(field = document.querySelector('#identifierId')); i++) await sleep(250);
  if (!field) return 'no identifier field: ' + location.href;
  await sleep(1500);
  field.focus();
  document.execCommand('selectAll');
  document.execCommand('insertText', false, 'test@gmail.com');
  await sleep(700);
  const typed = field.value;
  (document.querySelector('#identifierNext button') || document.querySelector('#identifierNext')).click();
  const start = location.pathname;
  let text = '';
  for (let i = 0; i < 60; i++) {
    await sleep(250);
    text = document.body.innerText.replace(/\s+/g, ' ');
    if (location.pathname !== start || /secure|Couldn.t|Wrong|password|Enter your/i.test(text)) break;
  }
  await sleep(2000);
  text = document.body.innerText.replace(/\s+/g, ' ').slice(0, 600);
  return 'typed=' + typed + ' | ' + location.pathname + ' | ' + text;
})()
