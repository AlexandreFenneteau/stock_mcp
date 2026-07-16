"""
Local fast-agent client for the Stock Management demo.

Connects to the Stock Management MCP Server (see mcp-server/) over SSE,
authenticating via Entra ID OAuth (Authorization Code + PKCE, handled
automatically by fast-agent - see fast-agent.yaml).
"""

import asyncio

from fast_agent import FastAgent

# Create the application
fast = FastAgent("Stock Management Agent")


# Define the agent
@fast.agent(
    name="stock_agent",
    instruction="You are an assistant that manages a stock inventory using the connected MCP tools.",
    servers=["stock_mcp"],
    model="responses.gpt-5.4-mini",
)
async def main():
    # use the --model command line switch or agent arguments to change model
    async with fast.run() as agent:
        await agent.interactive()


if __name__ == "__main__":
    asyncio.run(main())
