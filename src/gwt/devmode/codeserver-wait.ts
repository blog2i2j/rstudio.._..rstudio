import { Socket } from "net";
import { createInterface } from "readline";
import { ENDPOINT } from "./codeserver-common";

let errorCount = 0;

const socket = new Socket();

socket.on('error', (err) => {

    errorCount += 1;
    if (errorCount > 100) {
        process.exit(1);
    }

    socket.connect(ENDPOINT);
});

const reader = createInterface({
    input: socket,
    crlfDelay: Infinity,
});

reader.once('line', (line) => {

    const status = JSON.parse(line);
    if (status.ready) {
        process.exit(0);
    }

    reader.on('line', (line) => {
        console.log(line);
        if (line.includes('The code server is ready')) {
            process.exit(0);
        }
    });

});

socket.connect(ENDPOINT);

