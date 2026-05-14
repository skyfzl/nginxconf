// 简单示例：打印请求信息到 error.log
function logRequest(r) {
    r.error(`Request for: ${r.uri}, method: ${r.method}`);
    r.return(200, `Hello from njs! You requested ${r.uri}\n`);
    console.log("Hello NJS!")
}

export default { logRequest };
