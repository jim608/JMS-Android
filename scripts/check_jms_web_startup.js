async (page) => {
  await page.addInitScript(() => {
    window.jmsStartupErrors = [];
    const record = reason => {
      const properties = {};
      for (const name of Object.getOwnPropertyNames(reason ?? {})) {
        const value = reason[name];
        properties[name] = typeof value === 'object' && value !== null
          ? Object.fromEntries(Object.getOwnPropertyNames(value).map(key => [key, String(value[key])]))
          : String(value);
      }
      window.jmsStartupErrors.push(properties);
    };
    window.addEventListener('error', event => record(event.error));
    window.addEventListener('unhandledrejection', event => record(event.reason));
  });
  const errors = [];
  const messages = [];
  page.on('pageerror', error => errors.push({message: error.message, stack: error.stack}));
  page.on('console', message => {
    if (message.type() === 'error') {
      messages.push(Promise.all(message.args().map(argument => argument.evaluate(value => String(value)))));
    }
  });
  await page.goto('http://127.0.0.1:8765');
  await page.waitForURL('**/#/login');
  await page.waitForTimeout(1000);
  const consoleErrors = await Promise.all(messages);
  const title = await page.title();
  return {
    status: errors.length === 0 && consoleErrors.length === 0 && title === 'JMS' ? 'PASS' : 'FAIL',
    url: page.url(), title, errors, consoleErrors,
    details: await page.evaluate(() => window.jmsStartupErrors)
  };
}
