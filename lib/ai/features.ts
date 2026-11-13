import {textInput,matchingInput,connectionInput,answerOutput,matchOutput} from "./validation.ts";
export const features = {
 connection_test:{permission:"configuration.ai_settings",module:"configuration",input:connectionInput,output:null,maxOutput:16},
 general:{permission:"ai.general",module:"ai",input:textInput,output:answerOutput,maxOutput:2048},
 inventory_matching:{permission:"ai.inventory",module:"inventory",input:matchingInput,output:matchOutput,maxOutput:2048},
} as const;
export type ImplementedFeature=keyof typeof features;
